/*
  ======================================================================
  ESP32 BioMonitor - MAX30102 (Oxímetro) + AD8232 (ECG) via BLE
  Nordic UART Service (NUS) + Legacy GATT + Processamento Digital de Sinais (DSP)
  ----------------------------------------------------------------------
  Compatível com:
    - Serial Bluetooth Terminal (Android / iOS) via Nordic UART Service (NUS)
    - Amber Vitals (Flutter Mobile App)
    - Amber Monitor Web (PC / Navegador via bridge.py)

  Hardware:
    ESP32-WROOM-32 DevKit
    MAX30102 (Oxímetro de Pulso I2C):
      VIN -> 3V3 / 5V
      GND -> GND
      SDA -> GPIO21
      SCL -> GPIO22

    AD8232 (ECG Analógico + Digital):
      3.3V   -> 3V3
      GND    -> GND
      OUTPUT -> GPIO34 (ADC1 canal 6)
      LO+    -> GPIO32 (Detecção de eletrodo solto +)
      LO-    -> GPIO33 (Detecção de eletrodo solto -)

  Matemática & Filtros ECG (DSP a 200 Hz -> decimação para 50 Hz):
    1. Filtro Notch IIR Biquad 60 Hz (elimina ruído da rede elétrica brasileira)
    2. Filtro Passa-Baixas Butterworth de 2ª ordem (corte em 35 Hz contra EMG)
    3. Remoção adaptativa de Baseline Wander (deriva da linha de base < 0.5 Hz)
    4. Algoritmo Pan-Tompkins para detecção robusta de pico R (QRS) e cálculo de BPM_ECG
    5. Modo Demonstração / Teste sintético integrado acionável via BLE ("DEMO")

  Payload BLE Telemetria (50 Hz):
    "IR,BPM,SPO2,FINGER_OK,ECG,LEADS_OFF,BPM_ECG\n"
  ======================================================================
*/

#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "MAX30105.h"
#include "spo2_algorithm.h"

// -------------------------------------------------------------------------
// UUIDs BLE
// -------------------------------------------------------------------------
// Nordic UART Service (NUS) - Padrão universal para terminais seriais BLE
#define NUS_SERVICE_UUID      "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define NUS_CHAR_RX_UUID      "6e400002-b5a3-f393-e0a9-e50e24dcca9e" // Write / WriteNR
#define NUS_CHAR_TX_UUID      "6e400003-b5a3-f393-e0a9-e50e24dcca9e" // Notify

// Serviço Legado BioMonitor (compatibilidade com versões anteriores)
#define LEGACY_SERVICE_UUID   "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define LEGACY_CHAR_UUID      "beb5483e-36e1-4688-b7f5-ea07361b26a8"

// -------------------------------------------------------------------------
// Pinos de Hardware
// -------------------------------------------------------------------------
const int PINO_SDA = 21;
const int PINO_SCL = 22;

const int PINO_ECG_OUTPUT = 34; // ADC1_CH6
const int PINO_LO_PLUS    = 32;
const int PINO_LO_MINUS   = 33;

// -------------------------------------------------------------------------
// Sensores e Objetos
// -------------------------------------------------------------------------
MAX30105 sensorMax30102;
bool max30102Presente = false;

// Variáveis BLE
BLEServer* pServer = NULL;
BLECharacteristic* pNusTxChar = NULL;
BLECharacteristic* pNusRxChar = NULL;
BLECharacteristic* pLegacyChar = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// Modo Demo no firmware (permite testar pelo Serial Bluetooth Terminal sem fios)
bool modoDemoAtivo = false;
float tempoSintetico = 0.0f;

// Buffer para o algoritmo SparkFun MAX30102
const byte TAMANHO_BUFFER = 100;
uint32_t bufferIR[TAMANHO_BUFFER];
uint32_t bufferRed[TAMANHO_BUFFER];
byte indiceBuffer = 0;

int32_t spo2 = 0;
int8_t  spo2Valido = 0;
int32_t batimentosPorMinuto = 0;
int8_t  bpmValido = 0;
uint32_t ultimoIR = 0;
bool dedoPresente = false;
const uint32_t LIMIAR_DEDO_PRESENTE = 50000;

// -------------------------------------------------------------------------
// PROCESSAMENTO DIGITAL DE SINAIS (DSP) PARA ECG
// Amostragem a 200 Hz (5ms) com decimação 4:1 para transmissão a 50 Hz (20ms)
// -------------------------------------------------------------------------
// Filtro Notch IIR Biquad 60 Hz @ Fs = 200 Hz:
// H(z) = (b0 + b1*z^-1 + b2*z^-2) / (1 + a1*z^-1 + a2*z^-2)
const float NOTCH_B0 = 0.92244458f;
const float NOTCH_B1 = 0.57010210f;
const float NOTCH_B2 = 0.92244458f;
const float NOTCH_A1 = 0.56859127f;
const float NOTCH_A2 = 0.84640000f;
float notch_x1 = 0.0f, notch_x2 = 0.0f;
float notch_y1 = 0.0f, notch_y2 = 0.0f;

// Filtro Passa-Baixas Butterworth 2ª Ordem @ 35 Hz, Fs = 200 Hz:
const float LP_B0 = 0.16748380f;
const float LP_B1 = 0.33496760f;
const float LP_B2 = 0.16748380f;
const float LP_A1 = -0.55703100f;
const float LP_A2 = 0.22696620f;
float lp_x1 = 0.0f, lp_x2 = 0.0f;
float lp_y1 = 0.0f, lp_y2 = 0.0f;

// Remoção adaptativa de deriva de linha de base (Baseline Wander)
float ecgBaselineLenta = 2048.0f;
float ecgSinalFiltradoFinal = 2048.0f;

// -------------------------------------------------------------------------
// Algoritmo Pan-Tompkins para Detecção do Complexo QRS / Pico R
// -------------------------------------------------------------------------
float ptDiffBuffer[5] = {0};
const int MWI_WINDOW = 30; // ~150 ms a 200 Hz
float ptMwiBuffer[MWI_WINDOW] = {0};
int ptMwiIdx = 0;
float ptMwiSum = 0.0f;

float ptThreshold = 200.0f;
float ptMaxPeak = 400.0f;
unsigned long ultimoPicoRMs = 0;
int32_t bpmEcg = 0;
int8_t  bpmEcgValido = 0;
bool estadoQrsAtivo = false;
const unsigned long REFRATARIO_MS = 250;     // ~240 bpm máximo fisiológico
const unsigned long TIMEOUT_PICO_MS = 3000;  // 3s sem pico invalida BPM

// Temporização das rotinas
unsigned long ultimoAmostragemEcgUs = 0;
const unsigned long INTERVALO_ECG_US = 5000;   // 200 Hz = 5000 us

unsigned long ultimoEnvioBleUs = 0;
const unsigned long INTERVALO_BLE_US = 20000;  // 50 Hz = 20000 us

// -------------------------------------------------------------------------
// Gerador Sintético de ECG (Gaussiano P-Q-R-S-T) para Modo Demo
// -------------------------------------------------------------------------
float calculaGaussiana(float x, float mu, float sigma, float amp) {
  float diff = x - mu;
  return amp * expf(-(diff * diff) / (2.0f * sigma * sigma));
}

float sintetizaOndaECG(float t) {
  const float periodo = 3.0f; // ciclo de ~1 batimento/s
  float fase = fmodf(t, periodo) / periodo;
  float ecg = calculaGaussiana(fase, 0.18f, 0.035f, 45.0f)   // Onda P
            - calculaGaussiana(fase, 0.30f, 0.018f, 65.0f)   // Onda Q
            + calculaGaussiana(fase, 0.33f, 0.022f, 480.0f)  // Onda R (Pico agudo)
            - calculaGaussiana(fase, 0.36f, 0.018f, 130.0f)  // Onda S
            + calculaGaussiana(fase, 0.55f, 0.070f, 95.0f);  // Onda T
  return 2048.0f + ecg;
}

// -------------------------------------------------------------------------
// Callbacks BLE
// -------------------------------------------------------------------------
class ServidorCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println(F("[BLE] Cliente conectado!"));
  }
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println(F("[BLE] Cliente desconectado."));
  }
};

class NusRxCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    String rxValue = pCharacteristic->getValue();
    if (rxValue.length() > 0) {
      rxValue.trim();
      rxValue.toUpperCase();
      Serial.print(F("[BLE RX] Comando recebido: "));
      Serial.println(rxValue);

      if (rxValue == "DEMO" || rxValue == "TEST") {
        modoDemoAtivo = !modoDemoAtivo;
        String resp = modoDemoAtivo ? "MODO DEMO ATIVADO\n" : "MODO SENSOR REAL ATIVADO\n";
        pNusTxChar->setValue((uint8_t*)resp.c_str(), resp.length());
        pNusTxChar->notify();
      } else if (rxValue == "PING") {
        String resp = "PONG\n";
        pNusTxChar->setValue((uint8_t*)resp.c_str(), resp.length());
        pNusTxChar->notify();
      } else if (rxValue == "HELP") {
        String resp = "COMANDOS: DEMO, REAL, PING\n";
        pNusTxChar->setValue((uint8_t*)resp.c_str(), resp.length());
        pNusTxChar->notify();
      } else if (rxValue == "REAL") {
        modoDemoAtivo = false;
        String resp = "MODO SENSOR REAL ATIVADO\n";
        pNusTxChar->setValue((uint8_t*)resp.c_str(), resp.length());
        pNusTxChar->notify();
      }
    }
  }
};

// -------------------------------------------------------------------------
// Inicialização do BLE com NUS + Legacy Service
// -------------------------------------------------------------------------
void setupBLE() {
  BLEDevice::init("ESP32-BioMonitor");

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServidorCallbacks());

  // 1. Configuração do Nordic UART Service (NUS)
  BLEService *pNusService = pServer->createService(NUS_SERVICE_UUID);

  pNusTxChar = pNusService->createCharacteristic(
                 NUS_CHAR_TX_UUID,
                 BLECharacteristic::PROPERTY_NOTIFY
               );
  pNusTxChar->addDescriptor(new BLE2902());

  pNusRxChar = pNusService->createCharacteristic(
                 NUS_CHAR_RX_UUID,
                 BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
               );
  pNusRxChar->setCallbacks(new NusRxCallbacks());
  pNusService->start();

  // 2. Configuração do Serviço Legado (Retrocompatibilidade)
  BLEService *pLegacyService = pServer->createService(LEGACY_SERVICE_UUID);
  pLegacyChar = pLegacyService->createCharacteristic(
                  LEGACY_CHAR_UUID,
                  BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
                );
  pLegacyChar->addDescriptor(new BLE2902());
  pLegacyService->start();

  // 3. Advertising BLE
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(NUS_SERVICE_UUID);
  pAdvertising->addServiceUUID(LEGACY_SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06); // Parâmetros otimizados para conexão rápida iPhone/Android
  pAdvertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println(F("[BLE] 'ESP32-BioMonitor' ativo com Nordic UART Service (NUS) e Serviço Legado!"));
}

// -------------------------------------------------------------------------
// Inicialização do Sensor MAX30102
// -------------------------------------------------------------------------
bool setupMax30102() {
  pinMode(PINO_SDA, INPUT_PULLUP);
  pinMode(PINO_SCL, INPUT_PULLUP);
  Wire.begin(PINO_SDA, PINO_SCL);
  Wire.setClock(100000);

  const int TENTATIVAS = 4;
  for (int i = 0; i < TENTATIVAS; i++) {
    if (sensorMax30102.begin(Wire, I2C_SPEED_STANDARD)) {
      byte brilhoLED      = 60;
      byte mediaAmostras   = 4;
      byte modoLED         = 2;    // Red + IR
      byte taxaAmostragem  = 100;  // 100Hz
      int  larguraPulso    = 411;
      int  faixaADC        = 4096;

      sensorMax30102.setup(brilhoLED, mediaAmostras, modoLED, taxaAmostragem,
                            larguraPulso, faixaADC);
      return true;
    }
    Serial.println(F("[MAX30102] Tentando detectar sensor na I2C..."));
    delay(300);
  }
  return false;
}

// -------------------------------------------------------------------------
// Leitura e Algoritmo do MAX30102
// -------------------------------------------------------------------------
void atualizaMax30102() {
  if (!max30102Presente) return;

  sensorMax30102.check();
  if (!sensorMax30102.available()) return;

  uint32_t irAtual = sensorMax30102.getIR();
  uint32_t redAtual = sensorMax30102.getRed();
  sensorMax30102.nextSample();

  ultimoIR = irAtual;
  bufferIR[indiceBuffer] = irAtual;
  bufferRed[indiceBuffer] = redAtual;
  indiceBuffer++;

  if (indiceBuffer < TAMANHO_BUFFER) return;
  indiceBuffer = 0;

  uint64_t somaIR = 0;
  for (byte i = 0; i < TAMANHO_BUFFER; i++) somaIR += bufferIR[i];
  uint32_t mediaIR = somaIR / TAMANHO_BUFFER;
  dedoPresente = (mediaIR >= LIMIAR_DEDO_PRESENTE);

  if (dedoPresente) {
    int32_t tamanhoInt = TAMANHO_BUFFER;
    maxim_heart_rate_and_oxygen_saturation(
      bufferIR, tamanhoInt, bufferRed,
      &spo2, &spo2Valido, &batimentosPorMinuto, &bpmValido
    );
  } else {
    bpmValido = 0;
    spo2Valido = 0;
  }
}

// -------------------------------------------------------------------------
// Pipeline DSP de ECG a 200 Hz
// -------------------------------------------------------------------------
void processaAmostraEcgDsp(bool &leadsOff, int &ecgSaida) {
  leadsOff = (digitalRead(PINO_LO_PLUS) == HIGH) || (digitalRead(PINO_LO_MINUS) == HIGH);

  if (modoDemoAtivo) {
    tempoSintetico += 0.005f * 12.0f; // avanço de fase sintética
    float v = sintetizaOndaECG(tempoSintetico);
    ecgSaida = (int)v;
    leadsOff = false;
    bpmEcg = 75;
    bpmEcgValido = 1;
    return;
  }

  if (leadsOff) {
    ecgSaida = 0;
    bpmEcgValido = 0;
    estadoQrsAtivo = false;
    return;
  }

  float x0 = (float)analogRead(PINO_ECG_OUTPUT);

  // 1. Filtro Notch 60 Hz Biquad Direct Form II Transposed
  float y_notch = NOTCH_B0 * x0 + notch_x1;
  notch_x1 = NOTCH_B1 * x0 - NOTCH_A1 * y_notch + notch_x2;
  notch_x2 = NOTCH_B2 * x0 - NOTCH_A2 * y_notch;

  // 2. Filtro Passa-Baixas Butterworth 35 Hz
  float y_lp = LP_B0 * y_notch + lp_x1;
  lp_x1 = LP_B1 * y_notch - LP_A1 * y_lp + lp_x2;
  lp_x2 = LP_B2 * y_notch - LP_A2 * y_lp;

  // 3. Remoção de Drift de Linha de Base (High-Pass lento a ~0.5 Hz)
  ecgBaselineLenta += 0.008f * (y_lp - ecgBaselineLenta);
  float sinalLimpo = y_lp - ecgBaselineLenta;

  // Sinal centralizado em 2048 para plotagem padrão de 12-bit
  ecgSaida = (int)(2048.0f + sinalLimpo);
  if (ecgSaida < 0) ecgSaida = 0;
  if (ecgSaida > 4095) ecgSaida = 4095;

  // -----------------------------------------------------------------------
  // 4. Detecção de Pico R (Pan-Tompkins Simplificado)
  // -----------------------------------------------------------------------
  // Atualiza buffer da derivada
  ptDiffBuffer[4] = ptDiffBuffer[3];
  ptDiffBuffer[3] = ptDiffBuffer[2];
  ptDiffBuffer[2] = ptDiffBuffer[1];
  ptDiffBuffer[1] = ptDiffBuffer[0];
  ptDiffBuffer[0] = sinalLimpo;

  // Derivada de 5 pontos
  float deriv = (2.0f * ptDiffBuffer[0] + ptDiffBuffer[1] - ptDiffBuffer[3] - 2.0f * ptDiffBuffer[4]) / 8.0f;
  float derivSq = deriv * deriv;

  // Moving Window Integrator (MWI)
  ptMwiSum -= ptMwiBuffer[ptMwiIdx];
  ptMwiBuffer[ptMwiIdx] = derivSq;
  ptMwiSum += derivSq;
  ptMwiIdx = (ptMwiIdx + 1) % MWI_WINDOW;
  float mwiVal = ptMwiSum / (float)MWI_WINDOW;

  unsigned long agora = millis();
  float limiarDinamico = max(ptThreshold, 180.0f);

  if (!estadoQrsAtivo && mwiVal > limiarDinamico && (agora - ultimoPicoRMs) > REFRATARIO_MS) {
    estadoQrsAtivo = true;

    if (ultimoPicoRMs != 0) {
      unsigned long intervaloMs = agora - ultimoPicoRMs;
      if (intervaloMs >= REFRATARIO_MS && intervaloMs <= 2200) {
        int32_t bpmInstantaneo = 60000 / intervaloMs;
        bpmEcg = (bpmEcgValido) ? (bpmEcg * 3 + bpmInstantaneo) / 4 : bpmInstantaneo;
        bpmEcgValido = 1;
      }
    }
    ultimoPicoRMs = agora;

    // Atualiza limiar adaptativo
    ptMaxPeak += 0.25f * (mwiVal - ptMaxPeak);
    ptThreshold = ptMaxPeak * 0.45f;
  } else if (mwiVal < limiarDinamico * 0.4f) {
    estadoQrsAtivo = false;
  }

  // Decaimento suave do limiar para acompanhar atenuações de amplitude
  ptThreshold *= 0.9995f;

  if (bpmEcgValido && (agora - ultimoPicoRMs) > TIMEOUT_PICO_MS) {
    bpmEcgValido = 0;
  }
}

// -------------------------------------------------------------------------
// Envio da Telemetria por BLE (50 Hz)
// Formato: "IR,BPM,SPO2,FINGER_OK,ECG,LEADS_OFF,BPM_ECG\n"
// -------------------------------------------------------------------------
void enviaTelemetriaBLE(int ecgValor, bool leadsOff) {
  if (!deviceConnected) return;

  uint32_t irEnvio = ultimoIR;
  int32_t bpmEnvio = (bpmValido && dedoPresente) ? batimentosPorMinuto : 0;
  int32_t spo2Envio = (spo2Valido && dedoPresente) ? spo2 : 0;
  int dedoEnvio = dedoPresente ? 1 : 0;

  if (modoDemoAtivo) {
    irEnvio = 95000 + (uint32_t)(15000.0f * sinf(tempoSintetico * 0.3f));
    bpmEnvio = 75;
    spo2Envio = 98;
    dedoEnvio = 1;
  }

  char payload[64];
  int len = snprintf(payload, sizeof(payload), "%u,%ld,%ld,%d,%d,%d,%ld\n",
                     irEnvio,
                     bpmEnvio,
                     spo2Envio,
                     dedoEnvio,
                     ecgValor,
                     leadsOff ? 1 : 0,
                     bpmEcgValido ? bpmEcg : 0);

  if (len > 0) {
    // 1. Envia via Nordic UART Service (TX Notify)
    if (pNusTxChar != NULL) {
      pNusTxChar->setValue((uint8_t*)payload, (size_t)len);
      pNusTxChar->notify();
    }
    // 2. Envia via Serviço Legado
    if (pLegacyChar != NULL) {
      pLegacyChar->setValue((uint8_t*)payload, (size_t)len);
      pLegacyChar->notify();
    }
  }
}

// -------------------------------------------------------------------------
// Setup Principal
// -------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println(F("\n======================================================="));
  Serial.println(F("   ESP32 BioMonitor v2.0 - ECG DSP + MAX30102 BLE      "));
  Serial.println(F("   Nordic UART Service (NUS) + Legacy GATT Server       "));
  Serial.println(F("======================================================="));

  pinMode(PINO_LO_PLUS, INPUT);
  pinMode(PINO_LO_MINUS, INPUT);
  analogReadResolution(12);

  max30102Presente = setupMax30102();
  if (max30102Presente) {
    Serial.println(F("[MAX30102] Oxímetro detectado e pronto na I2C."));
  } else {
    Serial.println(F("[MAX30102] Sensor não detectado. Prosseguindo com ECG."));
  }

  setupBLE();
}

// -------------------------------------------------------------------------
// Loop Principal
// -------------------------------------------------------------------------
void loop() {
  atualizaMax30102();

  unsigned long agoraUs = micros();

  // Pipeline ECG a 200 Hz (amostragem precisa para filtragem digital)
  static bool leadsOffAtual = true;
  static int ecgFiltradoAtual = 0;

  if (agoraUs - ultimoAmostragemEcgUs >= INTERVALO_ECG_US) {
    ultimoAmostragemEcgUs = agoraUs;
    processaAmostraEcgDsp(leadsOffAtual, ecgFiltradoAtual);
  }

  // Transmissão BLE a 50 Hz (compatível com telas e osciloscópios)
  if (agoraUs - ultimoEnvioBleUs >= INTERVALO_BLE_US) {
    ultimoEnvioBleUs = agoraUs;
    enviaTelemetriaBLE(ecgFiltradoAtual, leadsOffAtual);
  }

  // Tratamento de reconexão BLE
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    Serial.println(F("[BLE] Reiniciando advertising..."));
    oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }
}

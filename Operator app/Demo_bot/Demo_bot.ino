// =====================================================
// ESP32 AUTONOMOUS ROBOT — RAW I2C GYRO TURNS
// Gyro Z-axis via direct MPU register reads (no library)
// Works with ANY MPU9250 / MPU6050 clone at 0x68 or 0x69
// =====================================================

#include <WiFi.h>
#include <WebServer.h>
#include <Wire.h>
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"

// ─────────────────────────────────────────────────────
// DELIVERY RAMP SERVO (NATIVE LEDC FOR CORE 3.0)
// ─────────────────────────────────────────────────────
#define RAMP_SERVO_PIN 13
const int RAMP_CLOSED_ANGLE = 0;
const int RAMP_OPEN_ANGLE = 180;
bool rampOpen = false;

void writeServoAngle(int pin, int angle) {
  long us = map(angle, 0, 180, 500, 2500);
  uint32_t duty = (us * 65535) / 20000;
  ledcWrite(pin, duty);
}

// ─────────────────────────────────────────────────────
// WIFI ACCESS POINT
// ─────────────────────────────────────────────────────
const char* ssid     = "ESP32_ROBOT";
const char* password = "12345678";
WebServer server(80);

// ─────────────────────────────────────────────────────
// MOTOR PINS (L298N)
// ─────────────────────────────────────────────────────
#define IN1  26
#define IN2  27
#define IN3  25
#define IN4  33
#define ENA  14
#define ENB  32

// ─────────────────────────────────────────────────────
// ULTRASONIC — Non-blocking interrupt-driven HC-SR04
// ─────────────────────────────────────────────────────
#define TRIG_PIN 5
#define ECHO_PIN 18

// Shared between ISR and loop — must be volatile
volatile unsigned long _echoStart  = 0;
volatile unsigned long _echoDur    = 0;   // pulse width in µs (0 = no echo / timeout)
volatile bool          _echoReady  = false;
volatile bool          _trigFired  = false;

// ISR: called on BOTH edges of the ECHO pin
void IRAM_ATTR echoISR() {
  if (digitalRead(ECHO_PIN) == HIGH) {
    _echoStart = micros();  // Rising edge — start timing
  } else {
    if (_trigFired) {
      _echoDur   = micros() - _echoStart;  // Falling edge — pulse complete
      _echoReady = true;
      _trigFired = false;
    }
  }
}

// Call once per loop cycle: fires the trigger pulse (non-blocking, 10 µs)
static unsigned long _lastTrigMs = 0;
void triggerUltrasonic() {
  unsigned long now = millis();
  if (now - _lastTrigMs < 100) return;  // Rate-limit to ~10 Hz — gives HC-SR04 full echo time before next trigger
  _lastTrigMs = now;
  _echoReady = false;
  _echoDur   = 0;
  _echoStart = 0;
  _trigFired = true;
  digitalWrite(TRIG_PIN, LOW);  delayMicroseconds(2);
  digitalWrite(TRIG_PIN, HIGH); delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);
}

// Read last captured distance (cm). Returns -1 if reading still in flight, 999 if clear/timeout.
long readUltrasonic() {
  if (_echoReady) {
    _echoReady = false;
    _trigFired = false;
    if (_echoDur == 0) return 999;
    // Guard against integer overflow or spurious very-long pulses (> 25ms = beyond 425cm physical max)
    if (_echoDur > 25000UL) return 999;
    long d = (long)(_echoDur * 0.034f / 2);
    return (d < 2 || d > 400) ? 999 : d;  // Filter: 2–400 cm valid range
  }
  // Safety timeout: if trigger fired and 30ms passed with no echo, path is clear
  if (_trigFired && (millis() - _lastTrigMs > 30)) {
    _trigFired = false;
    return 999;
  }
  return -1; // Echo still in flight
}

// ─────────────────────────────────────────────────────
// SPEED & CALIBRATION SETTINGS
// ─────────────────────────────────────────────────────
const int PWM_FREQ       = 1000;
const int PWM_RESOLUTION = 8;

int cruiseSpeed = 255;
int slowSpeed   = 255;
int turnSpeed   = 255;  // Maximum speed/torque for heavy payload turns

// Calibration multipliers (1.0 = 100% speed).
// Adjust via /calibrate endpoint from the Operator App after observing real-world straight-line behaviour:
// - If bot drifts RIGHT while forward  → RIGHT motor is stronger → reduce RIGHT_MOTOR_BIAS
// - If bot drifts LEFT  while forward  → LEFT  motor is stronger → reduce LEFT_MOTOR_BIAS
// Start at 1.00 / 1.00 (neutral). The heading PID handles small continuous drift;
// use these biases only for a persistent hardware imbalance the PID cannot fully correct.
float LEFT_MOTOR_BIAS  = 1.00f;   // Neutral baseline — fine-tune via /calibrate if needed
float RIGHT_MOTOR_BIAS = 1.00f;   // Neutral baseline — fine-tune via /calibrate if needed

// ─────────────────────────────────────────────────────
// PID TUNING CONSTANTS
// ─────────────────────────────────────────────────────
// Straight driving PID — higher Kp = faster drift correction
float straight_Kp = 8.0f;   // Proportional: stronger correction for left/right drift
float straight_Ki = 0.05f;  // Integral: slowly eliminates steady-state offset
float straight_Kd = 0.3f;   // Derivative: dampens oscillation

// 90° turn PID — tuned for accurate, non-oscillating 90° pivot
// NOTE: The turn function uses a SPEED PROFILE (not PID output) to drive the
// motors. Kp/Ki/Kd are kept for potential future use but the primary control
// path uses fixed speed tiers based on distance-to-target.
float turn_Kp     = 4.5f;   // (reserved — not used in primary path)
float turn_Ki     = 0.005f; // (reserved)
float turn_Kd     = 0.5f;   // (reserved)

// Speed profile for gyro pivot turns.
// Top speed at all distances — bot turns fast and stops precisely on target.
const int   TURN_SPEED_FAST   = 255;  // PWM when |error| > 30° — full torque
const int   TURN_SPEED_MEDIUM = 235;  // PWM when 15° < |error| ≤ 30°
const int   TURN_SPEED_SLOW   = 200;  // PWM when  6° < |error| ≤ 15°
const int   TURN_SPEED_FINE   = 170;  // PWM when  0° < |error| ≤  6°
const int   TURN_MIN_PWM      = 170;  // Minimum effective PWM — never stall

// Tolerance and settling — stop motors once inside tolerance, then settle.
const float          TURN_STOP_TOLERANCE = 2.5f;    // degrees — stop pivot here (looser = less overshoot at high speed)
const unsigned long  TURN_SETTLE_MS      = 100UL;   // ms to hold stop before returning

#define DIST_STOP 25   // cm — stop and reroute when obstacle within this range
#define DIST_SLOW 45   // cm — slow down zone (mission mode)

// ─────────────────────────────────────────────────────
// RAW I2C MPU REGISTERS
// ─────────────────────────────────────────────────────
#define MPU_ADDR      0x68   // Confirmed by I2C scanner

#define REG_WHO_AM_I  0x75
#define REG_PWR_MGMT1 0x6B
#define REG_PWR_MGMT2 0x6C
#define REG_SMPLRT    0x19
#define REG_DLPF_CFG  0x1A
#define REG_GYRO_CFG  0x1B
#define REG_GYRO_ZH   0x47
#define REG_GYRO_ZL   0x48

// ─────────────────────────────────────────────────────
// ACCELEROMETER REGISTERS (MPU9250 / MPU6050)
// ─────────────────────────────────────────────────────
#define REG_ACCEL_XH  0x3B   // ACCEL_XOUT_H
#define REG_ACCEL_XL  0x3C
#define REG_ACCEL_YH  0x3D   // ACCEL_YOUT_H
#define REG_ACCEL_YL  0x3E

#define GYRO_SCALE    131.0f   // LSB / (deg/s) for ±250 deg/s
#define ACCEL_SCALE   16384.0f // LSB / g  for  ±2 g  range

// Gain that converts lateral acceleration (g) → heading error correction (deg).
// Increase to react harder to sideways drift; decrease to reduce noise sensitivity.
const float ACCEL_CORRECTION_GAIN = 4.0f;

// Gyro state
float         currentYaw         = 0.0f;
float         gyroZ_offset       = 0.0f;
float         gyroZ_offset_stable = 0.0f;
unsigned long lastGyroUs         = 0;
bool          mpuReady           = false;
bool          mpuHardwarePresent = false;

// Accelerometer calibration offsets (lateral / forward, calibrated at rest)
float         accelX_offset      = 0.0f;  // Lateral axis bias (should be 0 on flat floor)
float         accelY_offset      = 0.0f;  // Forward axis bias

// I2C bus health flag — set when errors detected, handled in main loop
volatile bool i2cNeedsReset = false;

// ─────────────────────────────────────────────────────
// GYRO_Z_SIGN — SIGN CONVENTION
// ─────────────────────────────────────────────────────
// The MPU Z-axis positive direction depends on how the chip is mounted.
// Convention used here:
//   positive yaw  = robot turning RIGHT (clockwise from above)
//   negative yaw  = robot turning LEFT  (counter-clockwise from above)
//
// To turn RIGHT 90°: turnToAnglePID(+90.0f)  → target yaw = +90°
// To turn LEFT  90°: turnToAnglePID(-90.0f)  → target yaw = -90°
//
// If your bot turns the WRONG direction when commanded:
//   flip GYRO_Z_SIGN from -1.0f → +1.0f (or vice versa)
const float   GYRO_Z_SIGN  = -1.0f;  // -1.0f = chip mounted upside-down or Z inverted

const float          GYRO_DEADBAND          = 0.30f;   // deg/s — ignores tiny noise at rest
const float          TURN_TARGET            = 90.0f;   // degrees for a standard turn
const float          TURN_TOLERANCE         = 3.0f;    // deg — tighter = more accurate stops
const unsigned long  TURN_TIMEOUT_MS        = 4500UL;  // 4.5s timeout for 90° pivot (prevents spinning if stuck)
const unsigned long  TURN_STUCK_TIMEOUT_MS  = 1500UL;
const unsigned long  TURN_DEBUG_INTERVAL_MS =  200UL;

// ─────────────────────────────────────────────────────
// ROBOT STATE
// ─────────────────────────────────────────────────────
bool          running       = false;
String        currentDir    = "STOP";
String        robotMode     = "manual";
int           avoidPhase    = 0;
unsigned long phaseStart    = 0;
unsigned long turnDuration  = 0;
unsigned long reverseDur    = 350;
int           wanderTurnDir = 0;

// Pending gyro turn — executed from loop() so HTTP response fires first
bool          pendingTurn    = false;
bool          pendingTurnDir = false; // false=LEFT, true=RIGHT
unsigned long pendingTimerDur = 0;    // fallback timer duration
volatile bool abortActiveTurn = false;

// IMU Straight driving variables
bool          isStraightDriving   = false;
float         targetYaw           = 0.0f;
int           currentCommandSpeed = 255;

// PID State variables
float         straight_prevError  = 0.0f;
float         straight_integral   = 0.0f;
unsigned long straight_lastTimeMs = 0;
float         pendingTurnAngle    = 90.0f;

// Telemetry feedback variables for PID monitor
float         telemetryTargetYaw  = 0.0f;
float         telemetryYawError   = 0.0f;
float         telemetryPidOutput  = 0.0f;

RTC_DATA_ATTR int bootCount = 0;

// ─────────────────────────────────────────────────────
// LOCAL DECISION ENGINE — CONTINUOUS MISSION EXECUTION
// AMR-style: Sense → Decide → Act without stopping.
// ─────────────────────────────────────────────────────
enum MissionPhase {
  MP_MOVING_FORWARD,   // Normal cruise with MPU9250 PID heading correction
  MP_LDE_ASSESS,       // Obstacle hit — settling, choosing avoidance strategy
  MP_LDE_TURN_AWAY,    // Executing 90° pivot away from obstacle
  MP_LDE_BYPASS,       // Moving past the obstacle (minimum distance/time)
  MP_LDE_TURN_BACK,    // Executing 90° pivot back toward original heading
  MP_LDE_REVERSE,      // Reversing before retry when both sides are blocked
  MP_RECOVERY_FAILED   // All LDE_MAX_ATTEMPTS exhausted — notify operator
};

MissionPhase  missionPhase       = MP_MOVING_FORWARD;
int           lde_attempts       = 0;      // Full avoidance cycles used
bool          lde_triedLeft      = false;  // Left avoidance already attempted
bool          lde_triedRight     = false;  // Right avoidance already attempted
int           lde_avoidSide      = -1;     // -1 = LEFT pivot, +1 = RIGHT pivot
unsigned long lde_phaseStartMs   = 0;      // Timestamp when current phase began
bool          lde_phaseEntered   = false;  // One-shot guard for blocking phases
String        lde_stateLabel     = "IDLE"; // Telemetry: human-readable phase name

const int           LDE_MAX_ATTEMPTS    = 4;      // Avoidance cycles before FAILED
const unsigned long LDE_ASSESS_MS       = 150UL;  // Settle before deciding (ms)

// ─────────────────────────────────────────────────────
// FREERTOS MOTOR CONTROL TASK
// ─────────────────────────────────────────────────────
// Motor control runs on Core 1 (app core) to avoid blocking WiFi on Core 0.
// Commands are sent via queue from the main loop.
enum MotorCmdType {
  MC_NONE = 0,
  MC_TURN_PID,      // Gyro PID turn (relative angle)
  MC_TURN_TIMER,    // Timer-based pivot (no gyro)
  MC_MOVE_STRAIGHT, // PID-corrected straight driving
  MC_STOP,          // Emergency/clean stop
  MC_CALIBRATE_GYRO // Gyro calibration (non-blocking)
};

struct MotorCommand {
  MotorCmdType type;
  float        param1;    // angle for turn, speed for straight
  float        param2;    // additional param (e.g., turn direction, duration)
  bool         blocking;  // if true, sender waits for completion
  SemaphoreHandle_t done; // semaphore to signal completion
};

QueueHandle_t motorCmdQueue = nullptr;
TaskHandle_t  motorTaskHandle = nullptr;

// Motor task state
bool          motorTaskBusy = false;
bool          motorTaskCalibrating = false;
int           motorCalibSamples = 0;
double        motorCalibSum = 0.0;
float         motorCalibMin = 99999.0f;
float         motorCalibMax = -99999.0f;
int           motorAccelSamples = 0;
double        motorAccelAxSum = 0.0;
double        motorAccelAySum = 0.0;
const unsigned long LDE_BYPASS_MS       = 1500UL; // Min forward time past obstacle
const unsigned long LDE_BYPASS_EXTRA_MS = 600UL;  // Extra buffer if still near wall
const unsigned long LDE_REVERSE_MS      = 550UL;  // Reverse duration before retry

// LDE turn semaphore — motor task signals runMission() when turn is done
SemaphoreHandle_t lde_turnDoneSem = nullptr;
volatile bool     lde_turnOk      = false;   // result of last LDE turn (true=success)

// LDE turn protection — while an LDE turn is executing, HTTP commands
// MUST NOT set abortActiveTurn (or the turn will abort mid-manoeuvre).
volatile bool lde_turnProtected = false;

// 5-second watchdog — if bot is STOPPED in mission mode for > 5 s, force LDE.
const unsigned long LDE_WATCHDOG_MS = 5000UL;
unsigned long       lde_stoppedSinceMs = 0;  // millis() when stop was first noticed

// ─────────────────────────────────────────────────────
// FORWARD DECLARATIONS
// ─────────────────────────────────────────────────────
long    getDistance();
void    setSpeed(int s);
void    motorForward();
void    motorBackward();
void    motorStop(const char* caller);
void    turnLeftMotors();
void    turnRightMotors();

void    mpuWriteReg(uint8_t reg, uint8_t val);
uint8_t mpuReadReg(uint8_t reg);
int16_t mpuReadGyroZ_raw();
int16_t mpuReadGyroX_raw();
int16_t mpuReadGyroY_raw();
float   mpuReadGyroZ_dps();
void    mpuReadAccelXY(float &ax, float &ay);  // Lateral + forward accel in g

bool    initMPU();
void    calibrateGyro(int samples);
void    resetYaw();
void    updateYaw();
bool    turnLeft90();
bool    turnRight90();
void    runMission();    // LDE Continuous Mission Execution — called from loop()
void    startMission();
void    openRamp();
void    closeRamp();

// =====================================================
//  SETUP
// =====================================================
void setup() {
  WRITE_PERI_REG(RTC_CNTL_BROWN_OUT_REG, 0);

  Serial.begin(115200);
  WiFi.setSleep(false);
  WiFi.setTxPower(WIFI_POWER_19dBm);
  delay(300);

  // Motor pins
  pinMode(IN1, OUTPUT); pinMode(IN2, OUTPUT);
  pinMode(IN3, OUTPUT); pinMode(IN4, OUTPUT);
  ledcAttach(ENA, PWM_FREQ, PWM_RESOLUTION);
  ledcAttach(ENB, PWM_FREQ, PWM_RESOLUTION);
  setSpeed(cruiseSpeed);
  motorStop("setup");

  // Initialize Servo (50 Hz, 16-bit resolution)
  ledcAttach(RAMP_SERVO_PIN, 50, 16);
  closeRamp();

  // Ultrasonic — non-blocking interrupt-driven
  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);
  attachInterrupt(digitalPinToInterrupt(ECHO_PIN), echoISR, CHANGE);
  randomSeed(analogRead(34));

  // I2C bus scan
  Wire.begin(21, 22);
  Wire.setClock(100000);
  Wire.setTimeOut(3); // Set short timeout (3ms) to prevent watchdog starvation on I2C errors
  delay(500);

  Serial.println("[I2C] Scanning...");
  bool found = false;
  for (byte a = 8; a < 120; a++) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0) {
      Serial.printf("[I2C] Found: 0x%02X\n", a);
      found = true;
    }
  }
  if (!found) Serial.println("[I2C] No devices!");
  Serial.println("[I2C] Scan done.");

  // MPU init
  delay(200);
  mpuReady = initMPU();
  mpuHardwarePresent = mpuReady;
  if (mpuReady) {
    Serial.println("[GYRO] Calibrating — keep STILL...");
    delay(1000);
    calibrateGyro(500);
    gyroZ_offset_stable = gyroZ_offset; // Save boot calibration as stable
    mpuReady = true; // Force ready after boot calibration
    Serial.printf("[GYRO] Bias calibration completed. Offset: %.5f | Stable Offset: %.5f\n", gyroZ_offset, gyroZ_offset_stable);
  } else {
    Serial.println("[GYRO] MPU hardware not ready / detected!");
  }

  bootCount++;
  Serial.printf("[BOOT] Count = %d\n\n", bootCount);

  // LDE turn semaphore
  lde_turnDoneSem = xSemaphoreCreateBinary();

  // Initialize FreeRTOS motor control task (runs on Core 1)
  motorCmdQueue = xQueueCreate(10, sizeof(MotorCommand));
  xTaskCreatePinnedToCore(
    motorControlTask,
    "MotorControl",
    8192,        // Stack size
    nullptr,     // Parameters
    1,           // Priority
    &motorTaskHandle,
    1            // Core 1 (App core) — keeps WiFi on Core 0 responsive
  );
  Serial.println("[FREERTOS] Motor control task started on Core 1");

  // WiFi AP
  WiFi.softAP(ssid, password);
  Serial.printf("[WIFI] IP: %s\n", WiFi.softAPIP().toString().c_str());

  // ──────────────────────────────────────────────────
  //  HTTP ROUTES
  // ──────────────────────────────────────────────────

  server.on("/", HTTP_GET, []() {
    String html = "<!DOCTYPE html><html><head><title>ESP32 Robot</title>";
    html += "<style>body{background:#050816;color:#fff;text-align:center;font-family:Arial;padding-top:40px}";
    html += "button{width:180px;height:60px;font-size:22px;border:none;border-radius:14px;margin:12px;color:#fff;cursor:pointer}";
    html += ".go{background:#00c853}.stop{background:#ff1744}";
    html += "#st{font-size:26px;margin-top:28px}#tel{font-size:16px;margin-top:12px;color:#00e5ff}";
    html += "</style></head><body>";
    html += "<h1>ESP32 ROBOT</h1>";
    html += "<button class='go' onclick='startBot()'>START</button>";
    html += "<button class='stop' onclick='stopBot()'>STOP</button>";
    html += "<div id='st'>STOPPED</div><div id='tel'>Loading...</div>";
    html += "<script>";
    html += "async function startBot(){try{await fetch('/start');}catch(e){console.log(e);}}";
    html += "async function stopBot(){try{await fetch('/stop');}catch(e){console.log(e);}}";
    html += "async function poll(){";
    html += "  try{";
    html += "    const d=await(await fetch('/status')).json();";
    html += "    document.getElementById('st').textContent=d.running?'RUNNING':'STOPPED';";
    html += "    document.getElementById('tel').innerHTML='Dir:'+d.direction+' Mode:'+d.mode+'<br>Dist:'+d.distance+'cm Yaw:'+d.yaw.toFixed(1)+'<br>MPU:'+(d.mpu_ready?'OK':'Fallback');";
    html += "  }catch(e){document.getElementById('st').textContent='DISCONNECTED';}}";
    html += "setInterval(poll,800); poll();";   // Slower polling = more stable
    html += "</script></body></html>";
    server.send(200, "text/html", html);
  });

  server.on("/start", HTTP_GET, []() {
    // Respond immediately so the HTTP client does not time out
    // during the ~600 ms gyro calibration inside startMission().
    server.send(200, "text/plain", "STARTED");
    Serial.println("[MISSION] Started from web");
    if (!lde_turnProtected) abortActiveTurn = true;
    startMission();
  });

  server.on("/stop", HTTP_GET, []() {
    abortActiveTurn  = true;
    running          = false;
    turnDuration     = 0;
    pendingTurn      = false;
    robotMode        = "manual";
    // ── Reset LDE state machine ──────────────────────────
    missionPhase     = MP_MOVING_FORWARD;
    lde_attempts     = 0;
    lde_triedLeft    = false;
    lde_triedRight   = false;
    lde_phaseEntered = false;
    lde_stateLabel   = "IDLE";
    motorStop("stop_route");
    setSpeed(cruiseSpeed);
    server.send(200, "text/plain", "STOPPED");
    Serial.println("[MISSION] Stopped from web — LDE reset.");
  });

  server.on("/status", HTTP_GET, []() {
    long dist = getDistance();
    int16_t gz = mpuReady ? mpuReadGyroZ_raw() : 0;
    int currentLeftPWM = 0;
    int currentRightPWM = 0;
    if (currentDir != "STOP") {
      int targetSpeed = (currentDir == "LEFT" || currentDir == "RIGHT") ? turnSpeed : cruiseSpeed;
      currentLeftPWM = constrain((int)(targetSpeed * LEFT_MOTOR_BIAS), 0, 255);
      currentRightPWM = constrain((int)(targetSpeed * RIGHT_MOTOR_BIAS), 0, 255);
    } else {
      telemetryTargetYaw = 0.0f;
      telemetryYawError = 0.0f;
      telemetryPidOutput = 0.0f;
    }
    float battery = 12.2f - (millis() / 600000.0f); // simulated slow discharge
    if (battery < 9.0f) battery = 9.0f;
    battery += ((random(100) - 50) / 1000.0f); // add small voltage noise

    String j = "{";
    j += "\"running\":"     + String(running ? "true" : "false") + ",";
    j += "\"direction\":\"" + currentDir + "\",";
    j += "\"mode\":\""      + robotMode  + "\",";
    j += "\"distance\":"    + String(dist)       + ",";
    j += "\"yaw\":"         + String(currentYaw) + ",";
    j += "\"mpu_ready\":"   + String(mpuReady ? "true" : "false") + ",";
    j += "\"ramp_status\":\"" + String(rampOpen ? "OPEN" : "CLOSED") + "\",";
    j += "\"gyro_z\":"      + String(gz)         + ",";
    j += "\"pwm_left\":"    + String(currentLeftPWM) + ",";
    j += "\"pwm_right\":"   + String(currentRightPWM) + ",";
    j += "\"target_yaw\":"  + String(telemetryTargetYaw) + ",";
    j += "\"yaw_error\":"   + String(telemetryYawError) + ",";
    j += "\"pid_output\":"  + String(telemetryPidOutput) + ",";
    j += "\"battery\":"      + String(battery, 2)          + ",";
    j += "\"lde_state\":\""  + lde_stateLabel              + "\",";
    j += "\"lde_attempts\":" + String(lde_attempts);
    j += "}";
    server.send(200, "application/json", j);
  });

  server.on("/command", HTTP_GET, []() {
    // Check ramp parameter first — independent of motion commands
    if (server.hasArg("ramp")) {
      String rampCmd = server.arg("ramp");
      if (rampCmd == "open")  openRamp();
      else if (rampCmd == "close") closeRamp();
      server.send(200, "text/plain", "OK");
      return;
    }

    if (!server.hasArg("direction")) {
      server.send(400, "text/plain", "Missing direction"); return;
    }

    String dir = server.arg("direction");
    unsigned long cmdDuration = 0;
    if (server.hasArg("duration")) cmdDuration = server.arg("duration").toInt();

    // ── CRITICAL: Always force full cruise speed for FORWARD / BACKWARD ──
    // Any 'speed' arg from the operator is ignored for linear motion so the
    // bot always moves at maximum configured speed.
    int cmdSpeed = cruiseSpeed;  // always 255

    Serial.printf("[CMD] dir=%s speed=%d dur=%lums\n", dir.c_str(), cmdSpeed, cmdDuration);

    // ── Send HTTP response BEFORE any action ──────────────────────────────
    server.send(200, "text/plain", "OK");

    if (dir == "FORWARD") {
      // Abort any in-progress turn (unless LDE owns it)
      if (!lde_turnProtected) abortActiveTurn = true;
      isStraightDriving = false;  // force re-lock of heading on new forward
      moveStraightPID(cmdSpeed);  // always cruiseSpeed
      if (cmdDuration > 0) {
        running = true; robotMode = "auto";
        phaseStart = millis(); turnDuration = cmdDuration;
      }

    } else if (dir == "STOP") {
      if (!lde_turnProtected) abortActiveTurn = true;
      running = false; turnDuration = 0; pendingTurn = false;
      isStraightDriving = false;
      motorStop("cmd_stop");
      ledcWrite(ENA, 0); ledcWrite(ENB, 0);

    } else if (dir == "BACKWARD") {
      if (!lde_turnProtected) abortActiveTurn = true;
      isStraightDriving = false;
      setSpeed(cmdSpeed);  // always cruiseSpeed
      motorBackward();
      if (cmdDuration > 0) {
        running = true; robotMode = "auto";
        phaseStart = millis(); turnDuration = cmdDuration;
      }

    } else if (dir == "LEFT") {
      // Manual LEFT — 90° gyro pivot at full speed.
      // Guard: ignore if a turn is already in progress (prevents pile-up).
      // IMPORTANT: always reset running/turnDuration/robotMode so an accidental
      // 'duration' parameter can NEVER trigger the auto-timer path and conflict
      // with the gyro PID pendingTurn queue.
      if (!motorTaskBusy && !pendingTurn) {
        if (!lde_turnProtected) abortActiveTurn = true;
        isStraightDriving = false;
        running       = false;       // NOT an auto-timed run — gyro PID owns this
        turnDuration  = 0;           // clear any stale timer
        robotMode     = "manual";    // keep in manual mode during gyro pivot
        pendingTurn      = true;
        pendingTurnDir   = false;    // false = LEFT
        pendingTimerDur  = 0;        // unused when gyro is available
        pendingTurnAngle = 90.0f;    // fixed exact 90°
      } else {
        Serial.printf("[CMD] LEFT skipped — busy:%d pending:%d\n", motorTaskBusy, pendingTurn);
      }

    } else if (dir == "RIGHT") {
      // Manual RIGHT — 90° gyro pivot at full speed.
      // Same guards as LEFT above — see comment there.
      if (!motorTaskBusy && !pendingTurn) {
        if (!lde_turnProtected) abortActiveTurn = true;
        isStraightDriving = false;
        running       = false;
        turnDuration  = 0;
        robotMode     = "manual";
        pendingTurn      = true;
        pendingTurnDir   = true;     // true = RIGHT
        pendingTimerDur  = 0;
        pendingTurnAngle = 90.0f;    // fixed exact 90°
      } else {
        Serial.printf("[CMD] RIGHT skipped — busy:%d pending:%d\n", motorTaskBusy, pendingTurn);
      }
    }
  });

  server.on("/speed", HTTP_GET, []() {
    if (!server.hasArg("value")) { server.send(400, "text/plain", "Missing value"); return; }
    int val = server.arg("value").toInt();
    if (val < 0 || val > 255) { server.send(400, "text/plain", "Out of range"); return; }
    cruiseSpeed = val; setSpeed(cruiseSpeed);
    server.send(200, "text/plain", "OK");
  });

  // Lightweight yaw reset — resets heading reference without starting mission/LDE mode.
  // Called by the backend before each auto-navigation run to give the heading PID a fresh zero.
  server.on("/reset-yaw", HTTP_GET, []() {
    resetYaw();
    targetYaw       = 0.0f;
    isStraightDriving = false;
    server.send(200, "text/plain", "OK");
    Serial.println("[CMD] Yaw reset (non-blocking)");
  });

  server.on("/mode", HTTP_GET, []() {
    if (!server.hasArg("type")) { server.send(400, "text/plain", "Missing type"); return; }
    robotMode = server.arg("type");
    if (robotMode != "wander") { running = false; motorStop("mode_change"); }
    server.send(200, "text/plain", "OK");
  });

  // ── LIVE CALIBRATION ENDPOINT ─────────────────────────────────────
  // Usage examples:
  //   GET /calibrate?right=0.93          → set RIGHT_MOTOR_BIAS to 0.93
  //   GET /calibrate?left=0.98           → set LEFT_MOTOR_BIAS  to 0.98
  //   GET /calibrate?right=0.93&left=1.0 → set both at once
  //   GET /calibrate                     → returns current bias values
  server.on("/calibrate", HTTP_GET, []() {
    bool changed = false;
    if (server.hasArg("right")) {
      float val = server.arg("right").toFloat();
      val = constrain(val, 0.50f, 1.00f);  // Safety clamp
      RIGHT_MOTOR_BIAS = val;
      changed = true;
      Serial.printf("[CALIBRATE] RIGHT_MOTOR_BIAS set to %.3f\n", RIGHT_MOTOR_BIAS);
    }
    if (server.hasArg("left")) {
      float val = server.arg("left").toFloat();
      val = constrain(val, 0.50f, 1.00f);  // Safety clamp
      LEFT_MOTOR_BIAS = val;
      changed = true;
      Serial.printf("[CALIBRATE] LEFT_MOTOR_BIAS  set to %.3f\n", LEFT_MOTOR_BIAS);
    }
    if (changed && isStraightDriving) {
      // Apply new bias immediately to running motors
      setSpeed(currentCommandSpeed);
    }
    String resp = "{\"left\":" + String(LEFT_MOTOR_BIAS, 3) +
                  ",\"right\":" + String(RIGHT_MOTOR_BIAS, 3) + "}";
    server.send(200, "application/json", resp);
  });


  server.begin();
  Serial.println("[WIFI] HTTP server started");
  Serial.println("==============================");
  Serial.println("        ROBOT READY");
  Serial.printf ("  IP : %s\n", WiFi.softAPIP().toString().c_str());
  Serial.println("==============================\n");
}

// =====================================================
//  LOOP
// =====================================================
void loop() {
  server.handleClient();

  // ── Handle deferred I2C bus reset (flagged from ISR context) ──────────────────
  if (i2cNeedsReset) {
    i2cNeedsReset = false;
    Serial.println("[I2C] Resetting I2C bus in loop context...");
    Wire.end();
    delay(10);
    Wire.begin(21, 22);
    Wire.setClock(100000);
    Wire.setTimeOut(3);
    mpuReady = initMPU();
    if (mpuReady) {
      // Dispatch calibration to Core-1 motor task — avoids blocking WiFi for ~2.4 s
      MotorCommand calibCmd = {};
      calibCmd.type   = MC_CALIBRATE_GYRO;
      calibCmd.param1 = 500.0f;  // same sample count as boot calibration
      calibCmd.done   = nullptr; // fire-and-forget
      if (motorCmdQueue) xQueueSend(motorCmdQueue, &calibCmd, 0);
      Serial.println("[I2C] MPU re-initialized; calibration dispatched to motor task");
    } else {
      Serial.println("[I2C] MPU re-initialization FAILED after bus reset");
    }
  }

  // Continuous yaw tracking for straight stabilization and turns
  if (mpuReady) {
    updateYaw();
  }

  // Real-time heading correction for straight driving (FORWARD/BACKWARD) in all modes.
  if (mpuReady && isStraightDriving && (currentDir == "FORWARD" || currentDir == "BACKWARD")) {
    maintainHeadingPID(currentCommandSpeed);
  }

  // ── Execute pending manual turn — dispatched to Core-1 motor task ──────────
  // The HTTP handler sets pendingTurn = true and returns immediately.
  // Here we forward the turn to the FreeRTOS motor task (Core 1) via the queue
  // so the main loop (WiFi/server) is NEVER blocked for up to 4.5 s.
  // Guard: only dispatch if no turn is already running on the motor task.
  if (pendingTurn && !motorTaskBusy) {
    pendingTurn       = false;
    abortActiveTurn   = false;  // clear any stale abort flag
    isStraightDriving = false;
    running           = false;  // manual turn is never an "auto run"

    if (!motorCmdQueue) {
      Serial.println("[TURN] ERROR: motorCmdQueue not initialised — turn dropped");
    } else if (!mpuReady) {
      // ── Gyro unavailable: dispatch TIMER-BASED pivot to Core 1 ──────────
      unsigned long timerDur = (pendingTimerDur > 0) ? pendingTimerDur : 1700UL;
      MotorCommand cmd = {};
      cmd.type   = MC_TURN_TIMER;
      cmd.param1 = (float)timerDur;               // duration in ms
      cmd.param2 = pendingTurnDir ? 1.0f : 0.0f;  // 1=RIGHT, 0=LEFT
      cmd.done   = nullptr;                        // fire-and-forget
      xQueueSend(motorCmdQueue, &cmd, 0);
      Serial.printf("[TURN] Timer pivot %s %lums → queued to motor task\n",
                    pendingTurnDir ? "RIGHT" : "LEFT", timerDur);
    } else {
      // ── Gyro available: dispatch PID pivot to Core 1 ─────────────────
      // GYRO_Z_SIGN = -1.0f convention on this hardware:
      //   Physical LEFT  (CCW) → yaw INCREASES → relativeAngle = +pendingTurnAngle
      //   Physical RIGHT (CW)  → yaw DECREASES → relativeAngle = -pendingTurnAngle
      float relativeAngle = pendingTurnDir ? -pendingTurnAngle : +pendingTurnAngle;
      MotorCommand cmd = {};
      cmd.type   = MC_TURN_PID;
      cmd.param1 = relativeAngle;  // signed angle; sign encodes direction
      cmd.done   = nullptr;        // fire-and-forget
      xQueueSend(motorCmdQueue, &cmd, 0);
      Serial.printf("[TURN] PID pivot %.1f deg → queued to motor task\n", relativeAngle);
    }
  } else if (pendingTurn && motorTaskBusy) {
    // Motor task is still busy with a previous turn — drop and let the user re-issue
    pendingTurn = false;
    Serial.println("[TURN] Dropped — motor task still busy with previous turn");
  }


  // ── Ultrasonic — non-blocking trigger + read ─────────────
  triggerUltrasonic();          // fires trigger pulse every 60 ms
  static long  dist           = 999;
  static int   consecutiveObs = 0;
  long newDist = readUltrasonic();
  if (newDist == -1) {
    // Echo still in-flight — do NOT update dist or consecutiveObs.
    // Leaving the counter unchanged prevents stale counts from
    // accumulating on consecutive in-flight readings (false positives).
  } else {
    dist = newDist;
    if (dist <= DIST_STOP) {
      consecutiveObs++;
      if (consecutiveObs > 20) consecutiveObs = 20;  // cap to prevent overflow
    } else {
      consecutiveObs = 0;  // clear path — reset counter immediately
    }
  }

  // ── Heartbeat — 1 s ─────────────────────────────────────
  static unsigned long lastHbMs = 0;
  if (millis() - lastHbMs >= 1000) {
    lastHbMs = millis();
    Serial.printf("[HB] t=%lums heap=%uB mode=%s lde=%s run=%d dist=%ldcm yaw=%.1f\n",
                  millis(), ESP.getFreeHeap(), robotMode.c_str(),
                  lde_stateLabel.c_str(), (int)running, dist, currentYaw);
  }

  // ── Ultrasonic safety (manual/auto forward collision prevention) ──────────
  // In mission mode the LDE owns obstacle avoidance.
  // In wander mode the avoidPhase state machine handles it.
  // In manual & auto modes: stop immediately on obstacle to prevent collision.
  if (robotMode != "wander" && robotMode != "mission") {
    if (currentDir == "FORWARD" && consecutiveObs >= 3) {
      motorStop("ultrasonic_safety");
      running = false;
      turnDuration = 0;
      isStraightDriving = false;
      Serial.printf("[SAFETY] Obstacle at %ldcm — stopped forward motion\n", dist);
    }
  }

  // ── Auto timer ────────────────────────────────────────
  if (robotMode == "auto" && running && turnDuration > 0) {
    if (millis() - phaseStart >= turnDuration) {
      motorStop("auto_timer_expired");
      running = false; turnDuration = 0;
      Serial.println("[AUTO] Timer expired");
    }
  }

  // ── Continuous Mission Execution with Local Decision Engine ───────────
  // The robot remains RUNNING throughout all avoidance phases.
  // Only a true failure or manual /stop exits mission mode.
  if (robotMode == "mission" && running) {
    // ── 5-SECOND WATCHDOG ─────────────────────────────────────────
    // If motors are dead-stopped for > LDE_WATCHDOG_MS in any non-turn
    // LDE phase, force immediate LDE engagement (prevents silent freeze).
    bool inBlockingTurn = (missionPhase == MP_LDE_TURN_AWAY ||
                           missionPhase == MP_LDE_TURN_BACK);
    if (currentDir == "STOP" && !inBlockingTurn) {
      if (lde_stoppedSinceMs == 0) {
        lde_stoppedSinceMs = millis();
      } else if (millis() - lde_stoppedSinceMs >= LDE_WATCHDOG_MS) {
        lde_stoppedSinceMs = 0;
        Serial.println("[WATCHDOG] Bot stopped >5s in mission mode! Forcing LDE engage.");
        lde_phaseEntered = false;
        lde_triedLeft    = false;
        lde_triedRight   = false;
        missionPhase     = MP_LDE_ASSESS;
        lde_phaseStartMs = millis();
      }
    } else {
      lde_stoppedSinceMs = 0;  // Reset whenever motors are running or in a turn
    }
    runMission();
  }

  // ── Wander mode ────────────────────────────────────────────────
  if (robotMode == "wander" && running) {
    unsigned long now = millis();
    switch (avoidPhase) {
      case 0:
        if (consecutiveObs >= 3) {
          motorStop("wander_obs");
          wanderTurnDir = (random(2) == 0) ? 1 : -1;
          turnDuration  = random(450, 750);
          reverseDur    = random(300, 450);
          phaseStart = now; avoidPhase = 10; consecutiveObs = 0;
        } else if (dist <= DIST_SLOW) {
          setSpeed(slowSpeed); motorForward();
        } else {
          setSpeed(cruiseSpeed); motorForward();
        }
        break;
      case 10:
        if (now - phaseStart >= 60) {
          setSpeed(cruiseSpeed - 20); motorBackward();
          phaseStart = now; avoidPhase = 1;
        }
        break;
      case 1:
        if (now - phaseStart >= reverseDur) {
          motorStop("wander_rev"); phaseStart = now; avoidPhase = 20;
        }
        break;
      case 20:
        if (now - phaseStart >= 80) {
          setSpeed(turnSpeed);
          if (wanderTurnDir == 1) turnLeftMotors(); else turnRightMotors();
          phaseStart = now; avoidPhase = 2;
        }
        break;
      case 2:
        if (now - phaseStart >= turnDuration) {
          motorStop("wander_turn"); phaseStart = now; avoidPhase = 30;
        }
        break;
      case 30:
        if (now - phaseStart >= 80) {
          if (dist > DIST_STOP + 5) {
            avoidPhase = 0;
          } else {
            wanderTurnDir = -wanderTurnDir;
            turnDuration  = random(500, 850);
            setSpeed(turnSpeed);
            if (wanderTurnDir == 1) turnLeftMotors(); else turnRightMotors();
            phaseStart = now; avoidPhase = 2;
          }
        }
        break;
    }
  }

  delay(1);  // Yield to WiFi/RTOS tasks — keeps connection alive
}

// =====================================================
//  RAW I2C MPU HELPERS
// =====================================================

void mpuWriteReg(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(reg);
  Wire.write(val);
  Wire.endTransmission(true);
}

uint8_t mpuReadReg(uint8_t reg) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(reg);
  Wire.endTransmission(false);
  Wire.requestFrom((uint8_t)MPU_ADDR, (uint8_t)1, (uint8_t)true);
  return Wire.available() ? Wire.read() : 0xFF;
}

int16_t mpuReadGyroZ_raw() {
  static int zeroCount = 0;
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(REG_GYRO_ZH);
  byte error = Wire.endTransmission(false);

  if (error != 0) {
    zeroCount++;
    if (zeroCount > 10) {
      Serial.println("[I2C] Z-read error. Flagging I2C bus for reset...");
      i2cNeedsReset = true;
      zeroCount = 0;
    }
    return 0;
  }

  byte readBytes = Wire.requestFrom((uint8_t)MPU_ADDR, (uint8_t)2, (uint8_t)true);
  if (readBytes < 2) {
    zeroCount++;
    if (zeroCount > 15) {
      Serial.println("[I2C] Z-read consecutive zeros. Flagging I2C bus for reset...");
      i2cNeedsReset = true;
      zeroCount = 0;
    }
    return 0;
  }

  int16_t high = Wire.read();
  int16_t low = Wire.read();
  int16_t val = (high << 8) | low;

  if (val == 0) {
    zeroCount++;
    if (zeroCount > 15) {
      Serial.println("[I2C] Z-read consecutive zeros. Flagging I2C bus for reset...");
      i2cNeedsReset = true;
      zeroCount = 0;
    }
  } else {
    zeroCount = 0;
  }

  return val;
}

int16_t mpuReadGyroX_raw() {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x43); // REG_GYRO_XH
  if (Wire.endTransmission(false) != 0) return 0;
  if (Wire.requestFrom((uint8_t)MPU_ADDR, (uint8_t)2, (uint8_t)true) < 2) return 0;
  int16_t high = Wire.read();
  int16_t low = Wire.read();
  return (high << 8) | low;
}

int16_t mpuReadGyroY_raw() {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x45); // REG_GYRO_YH
  if (Wire.endTransmission(false) != 0) return 0;
  if (Wire.requestFrom((uint8_t)MPU_ADDR, (uint8_t)2, (uint8_t)true) < 2) return 0;
  int16_t high = Wire.read();
  int16_t low = Wire.read();
  return (high << 8) | low;
}

float mpuReadGyroZ_dps() {
  return mpuReadGyroZ_raw() / GYRO_SCALE;
}

// ─────────────────────────────────────────────────────
// mpuReadAccelXY() — read raw X and Y accelerometer axes
//   ax  = lateral acceleration (g)  positive = drifting RIGHT from forward
//   ay  = forward acceleration (g)  positive = moving forward
// Both axes calibrated via accelX_offset / accelY_offset (set in calibrateGyro)
// ─────────────────────────────────────────────────────
void mpuReadAccelXY(float &ax, float &ay) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(REG_ACCEL_XH);  // burst-read 4 bytes: XH XL YH YL
  byte err = Wire.endTransmission(false);
  if (err != 0) { ax = 0.0f; ay = 0.0f; return; }
  byte got = Wire.requestFrom((uint8_t)MPU_ADDR, (uint8_t)4, (uint8_t)true);
  if (got < 4)  { ax = 0.0f; ay = 0.0f; return; }
  int16_t xRaw = ((int16_t)Wire.read() << 8) | Wire.read();
  int16_t yRaw = ((int16_t)Wire.read() << 8) | Wire.read();
  ax = (float)xRaw / ACCEL_SCALE;
  ay = (float)yRaw / ACCEL_SCALE;
}

// ─────────────────────────────────────────────────────
// initMPU()
//   Wakes the MPU, enables gyro, sets DLPF + range.
//   Validates with 5 consecutive reads — if all zero,
//   marks gyro as non-functional (return false).
// ─────────────────────────────────────────────────────
bool initMPU() {
  Serial.println("[GYRO] Raw I2C init...");

  uint8_t whoAmI = mpuReadReg(REG_WHO_AM_I);
  Serial.printf("[GYRO] WHO_AM_I = 0x%02X", whoAmI);
  if      (whoAmI == 0x71) Serial.println(" (MPU9250)");
  else if (whoAmI == 0x70) Serial.println(" (MPU9255/clone)");
  else if (whoAmI == 0x68) Serial.println(" (MPU6050/clone)");
  else if (whoAmI == 0x19) Serial.println(" (MPU6050 variant)");
  else                     Serial.println(" (unknown — proceeding)");

  if (whoAmI == 0xFF) {
    Serial.println("[GYRO] No I2C response — check wiring!");
    return false;
  }

  // 1. Wake from sleep
  mpuWriteReg(REG_PWR_MGMT1, 0x00);
  delay(100);

  // 2. Enable all sensors (gyro + accel)
  mpuWriteReg(REG_PWR_MGMT2, 0x00);
  delay(20);

  // 3. DLPF ~44 Hz — smooth gyro, minimal lag
  mpuWriteReg(REG_DLPF_CFG, 0x03);

  // 4. Sample rate: 1 kHz / (1+7) = 125 Hz
  mpuWriteReg(REG_SMPLRT, 0x07);

  // 5. Gyro ±250 deg/s
  mpuWriteReg(REG_GYRO_CFG, 0x00);
  delay(50);

  // Validate: read 5 gyro samples — if ALL are zero, gyro not working
  Serial.println("[GYRO] Validating gyro reads...");
  int nonZeroCount = 0;
  for (int i = 0; i < 5; i++) {
    int16_t r = mpuReadGyroZ_raw();
    Serial.printf("[GYRO] Sample %d: %d\n", i + 1, r);
    if (r != 0) nonZeroCount++;
    delay(10);
  }

  if (nonZeroCount == 0) {
    // All reads were zero — gyro is not functioning
    // This will fall back to timer-based turns
    Serial.println("[GYRO] WARNING: All reads are 0 — gyro may not be functional");
    Serial.println("[GYRO] Using timer-based turns as fallback");
    return false;
  }

  Serial.println("[GYRO] MPU init OK");
  return true;
}

// ─────────────────────────────────────────────────────
// calibrateGyro() — average N samples for bias
// ─────────────────────────────────────────────────────
void calibrateGyro(int samples) {
  Serial.printf("[GYRO] Calibrating %d samples...\n", samples);
  double sum = 0.0;
  float minVal = 99999.0f;
  float maxVal = -99999.0f;

  for (int i = 0; i < samples; i++) {
    float g = mpuReadGyroZ_dps();
    sum += g;
    if (g < minVal) minVal = g;
    if (g > maxVal) maxVal = g;
    if (i % 100 == 0) Serial.printf("  Sample %d: %.3f\n", i, g);
    delay(4);
    // Keep WiFi alive — handle HTTP requests every 50 ms (~12 samples @ 4 ms each)
    if (i % 12 == 0) server.handleClient();
  }
  float new_offset = (float)(sum / samples);
  float spread = maxVal - minVal;
  Serial.printf("[GYRO] Bias = %.5f deg/s | Spread = %.3f deg/s\n", new_offset, spread);

  // If the spread is too high (vibration), revert to the last stable offset measured during boot setup.
  if (spread > 15.0f) {
    Serial.printf("[GYRO] WARNING: High vibration detected (Spread=%.3f). Reverting to stable offset: %.5f\n", spread, gyroZ_offset_stable);
    gyroZ_offset = gyroZ_offset_stable;
  } else {
    gyroZ_offset = new_offset;
    gyroZ_offset_stable = new_offset;
    Serial.printf("[GYRO] Accepted new offset: %.5f\n", gyroZ_offset);
  }

  // ── Accelerometer lateral/forward offset calibration ──────────────────────
  // Collect 150 samples (~600 ms) at rest to find the bias on each axis.
  Serial.println("[ACCEL] Calibrating lateral offset — keep STILL...");
  double axSum = 0.0, aySum = 0.0;
  const int ACCEL_SAMPLES = 150;
  for (int i = 0; i < ACCEL_SAMPLES; i++) {
    float ax, ay;
    mpuReadAccelXY(ax, ay);
    axSum += ax;
    aySum += ay;
    delay(4);
    // Keep WiFi alive every ~50 ms
    if (i % 12 == 0) server.handleClient();
  }
  accelX_offset = (float)(axSum / ACCEL_SAMPLES);
  accelY_offset = (float)(aySum / ACCEL_SAMPLES);
  Serial.printf("[ACCEL] Bias: X=%.5f g  Y=%.5f g\n", accelX_offset, accelY_offset);
}

// ─────────────────────────────────────────────────────
// motorControlTask() — FreeRTOS task for motor operations
// Runs on Core 1 to avoid blocking WiFi on Core 0
// ─────────────────────────────────────────────────────
void motorControlTask(void* parameter) {
  MotorCommand cmd;

  while (true) {
    if (xQueueReceive(motorCmdQueue, &cmd, portMAX_DELAY)) {
      motorTaskBusy = true;

      switch (cmd.type) {
        case MC_TURN_PID: {
          // Non-blocking turn state machine
          bool turningLeft = (cmd.param1 > 0.0f);
          const char* dirLabel = turningLeft ? "LEFT" : "RIGHT";
          float targetAngle = cmd.param1;

          Serial.printf("[MOTOR_TASK] Turn %s target=%.1f\n", dirLabel, targetAngle);

          // Pre-turn stop + brief settle
          motorStop("pid_turn_pre_settle");
          ledcWrite(ENA, 0); ledcWrite(ENB, 0);
          vTaskDelay(pdMS_TO_TICKS(150));

          resetYaw();

          // Set motor direction ONCE
          if (turningLeft) { turnLeftMotors(); }
          else             { turnRightMotors(); }

          // Start immediately at full turn speed — no slow ramp
          ledcWrite(ENA, TURN_SPEED_FAST);
          ledcWrite(ENB, TURN_SPEED_FAST);

          TickType_t startTicks = xTaskGetTickCount();
          TickType_t lastPrintTicks = 0;

          // Main pivot loop
          while (xTaskGetTickCount() - startTicks < pdMS_TO_TICKS(TURN_TIMEOUT_MS)) {
            if (abortActiveTurn) {
              Serial.println("[MOTOR_TASK] Turn aborted");
              motorStop("turn_aborted");
              ledcWrite(ENA, 0); ledcWrite(ENB, 0);
              resetYaw(); targetYaw = 0.0f;
              currentDir = "STOP"; isStraightDriving = false;
              if (cmd.done) xSemaphoreGive(cmd.done);
              motorTaskBusy = false;
              goto turn_cleanup;
            }

            updateYaw();
            float absError = fabsf(targetAngle - currentYaw);

            telemetryTargetYaw = targetAngle;
            telemetryYawError  = targetAngle - currentYaw;
            telemetryPidOutput = 0.0f;

            bool targetReached = false;
            if (turningLeft) {
              if (currentYaw >= (targetAngle - TURN_STOP_TOLERANCE)) targetReached = true;
            } else {
              if (currentYaw <= (targetAngle + TURN_STOP_TOLERANCE)) targetReached = true;
            }

            if (targetReached || absError <= TURN_STOP_TOLERANCE) {
              motorStop("turn_complete");
              ledcWrite(ENA, 0); ledcWrite(ENB, 0);
              Serial.printf("[MOTOR_TASK] Turn COMPLETE yaw=%.1f target=%.1f\n", currentYaw, targetAngle);

              vTaskDelay(pdMS_TO_TICKS(TURN_SETTLE_MS));

              resetYaw();
              targetYaw = 0.0f;
              currentDir = "STOP";
              running = false;
              isStraightDriving = false;
              if (cmd.done) xSemaphoreGive(cmd.done);
              motorTaskBusy = false;
              goto turn_cleanup;
            }

            // Speed profile — fast approach, decelerate near target
            int spd;
            if      (absError > 30.0f) spd = TURN_SPEED_FAST;    // 255
            else if (absError > 15.0f) spd = TURN_SPEED_MEDIUM;  // 235
            else if (absError >  6.0f) spd = TURN_SPEED_SLOW;    // 200
            else                       spd = TURN_SPEED_FINE;     // 170

            if (spd < TURN_MIN_PWM) spd = TURN_MIN_PWM;

            ledcWrite(ENA, spd);
            ledcWrite(ENB, spd);

            // Debug print every ~100 ms
            TickType_t now = xTaskGetTickCount();
            if (now - lastPrintTicks >= pdMS_TO_TICKS(100)) {
              lastPrintTicks = now;
              Serial.printf("[MOTOR_TASK] yaw=%.1f target=%.1f error=%.1f pwm=%d\n",
                            currentYaw, targetAngle, targetAngle - currentYaw, spd);
            }

            vTaskDelay(pdMS_TO_TICKS(2));
          }

          // Timeout path
          Serial.println("[MOTOR_TASK] Turn TIMEOUT!");
          motorStop("turn_timeout");
          ledcWrite(ENA, 0); ledcWrite(ENB, 0);
          resetYaw(); targetYaw = 0.0f;
          currentDir = "STOP"; running = false; isStraightDriving = false;
          if (cmd.done) xSemaphoreGive(cmd.done);
          motorTaskBusy = false;

          turn_cleanup:
          break;
        }

        case MC_TURN_TIMER: {
          // Timer-based pivot (no gyro)
          bool turnRight = (cmd.param2 > 0);
          unsigned long timerDur = (unsigned long)cmd.param1;

          Serial.printf("[MOTOR_TASK] Timer PIVOT %s %lums\n", turnRight ? "RIGHT" : "LEFT", timerDur);

          motorStop("pre_turn_settle");
          vTaskDelay(pdMS_TO_TICKS(80));

          if (turnRight) { turnRightMotors(); }
          else           { turnLeftMotors(); }

          ledcWrite(ENA, TURN_SPEED_FAST);
          ledcWrite(ENB, TURN_SPEED_FAST);
          vTaskDelay(pdMS_TO_TICKS(timerDur));

          motorStop("timer_turn_done");
          ledcWrite(ENA, 0); ledcWrite(ENB, 0);
          resetYaw(); targetYaw = 0.0f;
          currentDir = "STOP"; running = false; isStraightDriving = false;
          if (cmd.done) xSemaphoreGive(cmd.done);
          motorTaskBusy = false;
          break;
        }

        case MC_MOVE_STRAIGHT: {
          // PID-corrected straight driving - this runs continuously
          // For now, just signal completion as this is managed in loop()
          if (cmd.done) xSemaphoreGive(cmd.done);
          motorTaskBusy = false;
          break;
        }

        case MC_STOP: {
          motorStop("motor_task_stop");
          ledcWrite(ENA, 0); ledcWrite(ENB, 0);
          currentDir = "STOP"; running = false; isStraightDriving = false;
          if (cmd.done) xSemaphoreGive(cmd.done);
          motorTaskBusy = false;
          break;
        }

        case MC_CALIBRATE_GYRO: {
          // Non-blocking gyro calibration
          int samples = (int)cmd.param1;
          Serial.printf("[MOTOR_TASK] Calibrating gyro %d samples...\n", samples);

          motorTaskCalibrating = true;
          motorCalibSamples = 0;
          motorCalibSum = 0.0;
          motorCalibMin = 99999.0f;
          motorCalibMax = -99999.0f;

          while (motorCalibSamples < samples) {
            float g = mpuReadGyroZ_dps();
            motorCalibSum += g;
            if (g < motorCalibMin) motorCalibMin = g;
            if (g > motorCalibMax) motorCalibMax = g;
            motorCalibSamples++;

            if (motorCalibSamples % 100 == 0) {
              Serial.printf("[MOTOR_TASK] Calib sample %d: %.3f\n", motorCalibSamples, g);
            }

            vTaskDelay(pdMS_TO_TICKS(4));
          }

          float new_offset = (float)(motorCalibSum / samples);
          float spread = motorCalibMax - motorCalibMin;
          Serial.printf("[MOTOR_TASK] Bias = %.5f deg/s | Spread = %.3f deg/s\n", new_offset, spread);

          if (spread > 15.0f) {
            Serial.printf("[MOTOR_TASK] WARNING: High vibration (Spread=%.3f). Reverting to stable offset: %.5f\n", spread, gyroZ_offset_stable);
            gyroZ_offset = gyroZ_offset_stable;
          } else {
            gyroZ_offset = new_offset;
            gyroZ_offset_stable = new_offset;
            Serial.printf("[MOTOR_TASK] Accepted new offset: %.5f\n", gyroZ_offset);
          }

          // Accelerometer calibration
          Serial.println("[MOTOR_TASK] Calibrating accel — keep STILL...");
          motorAccelSamples = 0;
          motorAccelAxSum = 0.0;
          motorAccelAySum = 0.0;
          const int ACCEL_SAMPLES = 150;

          while (motorAccelSamples < ACCEL_SAMPLES) {
            float ax, ay;
            mpuReadAccelXY(ax, ay);
            motorAccelAxSum += ax;
            motorAccelAySum += ay;
            motorAccelSamples++;
            vTaskDelay(pdMS_TO_TICKS(4));
          }

          accelX_offset = (float)(motorAccelAxSum / ACCEL_SAMPLES);
          accelY_offset = (float)(motorAccelAySum / ACCEL_SAMPLES);
          Serial.printf("[MOTOR_TASK] Accel Bias: X=%.5f g  Y=%.5f g\n", accelX_offset, accelY_offset);

          motorTaskCalibrating = false;
          if (cmd.done) xSemaphoreGive(cmd.done);
          motorTaskBusy = false;
          break;
        }

        default:
          if (cmd.done) xSemaphoreGive(cmd.done);
          motorTaskBusy = false;
          break;
      }
    }

    vTaskDelay(pdMS_TO_TICKS(1));
  }
}

void resetYaw() {
  currentYaw = 0.0f;
  lastGyroUs = micros();
}

void updateYaw() {
  unsigned long nowUs = micros();
  float dt = (float)(nowUs - lastGyroUs) * 1e-6f;
  lastGyroUs = nowUs;

  float raw_gz = mpuReadGyroZ_dps();
  float gz = (raw_gz - gyroZ_offset) * GYRO_Z_SIGN;

  if (fabsf(gz) < GYRO_DEADBAND) gz = 0.0f;

  currentYaw += gz * dt;
}

// ─────────────────────────────────────────────────────
// startMission()
// ─────────────────────────────────────────────────────
void startMission() {
  Serial.println("[MISSION] Preparing for Continuous Mission Execution...");
  motorStop("mission_start");
  setSpeed(0);

  // ── Initialise LDE state machine ──────────────────────────
  missionPhase     = MP_MOVING_FORWARD;
  lde_attempts     = 0;
  lde_triedLeft    = false;
  lde_triedRight   = false;
  lde_phaseEntered = false;
  lde_avoidSide    = -1;
  lde_stateLabel   = "IDLE";
  abortActiveTurn  = false;

  // Wait 100 milliseconds for vibrations to settle
  delay(100);

  if (mpuHardwarePresent) {
    Serial.println("[MISSION] Calibrating gyro — KEEP STILL!");
    calibrateGyro(600);
    mpuReady = true; // Force ready
    resetYaw();
    Serial.println("[MISSION] Gyro calibration completed | Yaw = 0");
  } else {
    Serial.println("[MISSION] MPU hardware not detected!");
    mpuReady = false;
  }

  running    = true;
  avoidPhase = 0;
  robotMode  = "mission";   // ← Continuous Mission Execution mode (LDE active)
  lde_stateLabel = "MOVING";
  moveStraightPID(cruiseSpeed);  // Begin driving immediately
  Serial.println("[MISSION] *** CONTINUOUS MISSION EXECUTION STARTED ***");
  Serial.println("[MISSION] LDE active — robot will not stop unless truly blocked.");
}

// ─────────────────────────────────────────────────────
// turnToAnglePID() — deterministic gyro pivot
//
// relativeAngle > 0 → LEFT  pivot (yaw increases with GYRO_Z_SIGN=-1.0)
// relativeAngle < 0 → RIGHT pivot (yaw decreases with GYRO_Z_SIGN=-1.0)
//
// Key design decisions:
//  1. Motor direction is FIXED by the SIGN of relativeAngle at entry.
//     It does NOT flip L↔R based on PID output — that would cause oscillation.
//  2. Speed PROFILE (not PID) reduces PWM as |error| shrinks.
//  3. Motors stop HARD when |error| <= TURN_STOP_TOLERANCE.
//  4. A non-blocking settle period follows before returning.
//  5. server.handleClient() is called every 25 ms — WiFi stays alive.
// ─────────────────────────────────────────────────────
bool turnToAnglePID(float relativeAngle) {
  if (!mpuReady) {
    Serial.println("[TURN] Gyro not ready.");
    motorStop("gyro_not_ready");
    return false;
  }

  // Determine fixed turn direction from sign of relativeAngle.
  // This direction does NOT change during the turn — prevents oscillation.
  bool turningLeft = (relativeAngle > 0.0f);  // +angle = LEFT, −angle = RIGHT
  const char* dirLabel = turningLeft ? "LEFT" : "RIGHT";

  Serial.printf("[TURN] direction=%s target=%.1f\n", dirLabel, relativeAngle);

  // ── Pre-turn stop + brief non-blocking settle ───────────────────────────
  motorStop("pid_turn_pre_settle");
  ledcWrite(ENA, 0); ledcWrite(ENB, 0);
  { unsigned long _s = millis(); while (millis() - _s < 150) { server.handleClient(); yield(); delay(1); } }

  // Zero the relative yaw so the target is exactly relativeAngle degrees away.
  resetYaw();

  float targetAngle = relativeAngle;
  abortActiveTurn   = false;
  isStraightDriving = false;

  // ── Set motor direction ONCE ──────────────────────────────────────────
  if (turningLeft) { turnLeftMotors();  }
  else             { turnRightMotors(); }

  // ── Short acceleration ramp ───────────────────────────────────────────
  // Smoothly ramp from fine speed to fast speed over ~200ms
  for (int pwm = TURN_SPEED_FINE; pwm <= TURN_SPEED_FAST; pwm += 20) {
    ledcWrite(ENA, pwm);
    ledcWrite(ENB, pwm);
    // keep WiFi alive during ramp step
    unsigned long _r = millis();
    while (millis() - _r < 40) { server.handleClient(); yield(); delay(1); }
  }

  unsigned long startMs     = millis();
  unsigned long lastPrintMs = 0;
  unsigned long lastHandleMs = 0;

  // ── Main pivot loop ──────────────────────────────────────────────
  while (millis() - startMs < TURN_TIMEOUT_MS) {

    if (abortActiveTurn) {
      Serial.println("[TURN] Aborted.");
      motorStop("turn_aborted");
      ledcWrite(ENA, 0); ledcWrite(ENB, 0);
      resetYaw(); targetYaw = 0.0f;
      currentDir = "STOP"; isStraightDriving = false;
      return false;
    }

    updateYaw();
    float absError = fabsf(targetAngle - currentYaw);

    // Update telemetry
    telemetryTargetYaw = targetAngle;
    telemetryYawError  = targetAngle - currentYaw;
    telemetryPidOutput = 0.0f; // speed profile, not PID output

    // ── STOP CHECK: reached or crossed target, or within tolerance ─────
    bool targetReached = false;
    if (turningLeft) {
      if (currentYaw >= (targetAngle - TURN_STOP_TOLERANCE)) {
        targetReached = true;
      }
    } else {
      if (currentYaw <= (targetAngle + TURN_STOP_TOLERANCE)) {
        targetReached = true;
      }
    }

    if (targetReached || absError <= TURN_STOP_TOLERANCE) {
      // Hard stop — cut PWM immediately
      motorStop("turn_complete");
      ledcWrite(ENA, 0); ledcWrite(ENB, 0);
      Serial.printf("[TURN] COMPLETE yaw=%.1f target=%.1f\n", currentYaw, targetAngle);

      // Non-blocking settle before returning
      { unsigned long _e = millis(); while (millis() - _e < TURN_SETTLE_MS) { server.handleClient(); yield(); delay(1); } }

      // Clean up state
      resetYaw();
      targetYaw = 0.0f;
      currentDir = "STOP";
      running = false;
      isStraightDriving = false;
      return true;
    }

    // ── Speed profile ────────────────────────────────────────────────
    int spd;
    if      (absError > 45.0f) spd = TURN_SPEED_FAST;
    else if (absError > 20.0f) spd = TURN_SPEED_MEDIUM;
    else if (absError >  8.0f) spd = TURN_SPEED_SLOW;
    else                       spd = TURN_SPEED_FINE;

    if (spd < TURN_MIN_PWM) spd = TURN_MIN_PWM;

    // Equal PWM on both motors — no L/R bias (preserves pure pivot centre)
    ledcWrite(ENA, spd);
    ledcWrite(ENB, spd);

    // Debug print every ~100 ms
    unsigned long now = millis();
    if (now - lastPrintMs >= 100) {
      lastPrintMs = now;
      Serial.printf("[TURN] yaw=%.1f target=%.1f error=%.1f pwm=%d\n",
                    currentYaw, targetAngle, targetAngle - currentYaw, spd);
    }

    // Keep WiFi alive every 25 ms
    if (now - lastHandleMs >= 25) {
      lastHandleMs = now;
      server.handleClient();
    }

    yield();
    delay(2);
  }

  // Timeout path
  Serial.println("[TURN] TIMEOUT!");
  motorStop("turn_timeout");
  ledcWrite(ENA, 0); ledcWrite(ENB, 0);
  resetYaw(); targetYaw = 0.0f;
  currentDir = "STOP"; running = false; isStraightDriving = false;
  return false;
}

// ─────────────────────────────────────────────────────
// turnLeft90() — LEFT wrapper: positive angle (LEFT=+90 with GYRO_Z_SIGN=-1)
// ─────────────────────────────────────────────────────
bool turnLeft90() {
  return turnToAnglePID(+90.0f);   // LEFT  = positive yaw on this hardware
}

// ─────────────────────────────────────────────────────
// turnRight90() — RIGHT wrapper: negative angle (RIGHT=-90 with GYRO_Z_SIGN=-1)
// ─────────────────────────────────────────────────────
bool turnRight90() {
  return turnToAnglePID(-90.0f);   // RIGHT = negative yaw on this hardware
}

// =====================================================
//  runMission() — LOCAL DECISION ENGINE (LDE)
//  AMR-Style Continuous Mission Execution
//
//  Philosophy:
//    • Robot stays RUNNING at all times during a mission.
//    • Obstacles trigger IMMEDIATE autonomous recovery.
//    • Avoidance sequence: LEFT → RIGHT → REVERSE+retry
//    • After bypass: turns back and resumes original heading.
//    • Only exits mission on: max attempts, abort, or /stop.
//
//  State machine called from loop() — non-blocking except
//  for turnToAnglePID() which pumps server.handleClient()
//  internally every 25 ms (WiFi stays alive during turns).
// =====================================================
void runMission() {
  // ── Private ultrasonic state (rate-limited, only when moving) ─────────
  static unsigned long lde_lastDistMs = 0;
  static long          lde_dist       = 999;
  static int           lde_obstCount  = 0;

  bool sensing = (missionPhase == MP_MOVING_FORWARD || missionPhase == MP_LDE_BYPASS);
  if (sensing && millis() - lde_lastDistMs >= 50) {
    lde_lastDistMs = millis();
    lde_dist       = getDistance();
    lde_obstCount  = (lde_dist <= DIST_STOP) ? lde_obstCount + 1 : 0;
  }

  switch (missionPhase) {

    // ══════════════════════════════════════════════════════════════════
    case MP_MOVING_FORWARD: {
      lde_stateLabel = "MOVING";

      // Re-engage forward drive if somehow stopped (e.g. after turn-back)
      if (currentDir != "FORWARD") {
        moveStraightPID(cruiseSpeed);
      }

      // Continuous MPU9250 PID heading correction
      if (mpuReady && isStraightDriving) {
        maintainHeadingPID(currentCommandSpeed);
      }

      // Obstacle detected — require 2 consecutive reads to ignore noise
      if (lde_obstCount >= 2) {
        lde_obstCount  = 0;
        Serial.printf("\n[LDE] *** OBSTACLE @ %ldcm | Yaw=%.1f | Engaging LDE ***\n",
                      lde_dist, currentYaw);
        motorStop("lde_obstacle");

        // Reset avoidance tracking for this new obstacle encounter
        lde_triedLeft    = false;
        lde_triedRight   = false;
        lde_attempts     = 0;
        lde_phaseEntered = false;

        missionPhase     = MP_LDE_ASSESS;
        lde_phaseStartMs = millis();
      }
      break;
    }

    // ══════════════════════════════════════════════════════════════════
    case MP_LDE_ASSESS: {
      lde_stateLabel = "LDE_ASSESS";

      // Brief settle — lets transient sonar reflections clear, motors fully stop
      if (millis() - lde_phaseStartMs < LDE_ASSESS_MS) break;

      lde_attempts++;
      Serial.printf("[LDE] === Avoidance Attempt %d / %d ===\n",
                    lde_attempts, LDE_MAX_ATTEMPTS);

      if (lde_attempts > LDE_MAX_ATTEMPTS) {
        missionPhase = MP_RECOVERY_FAILED;
        break;
      }

      // Strategy: LEFT first (+90°) → RIGHT second (-90°) → REVERSE then alternate
      if (!lde_triedLeft) {
        lde_avoidSide = +1;   // Left pivot (+90°)
        Serial.println("[LDE] Strategy: TURN LEFT to avoid");
        lde_phaseEntered = false;
        missionPhase     = MP_LDE_TURN_AWAY;

      } else if (!lde_triedRight) {
        lde_avoidSide = -1;   // Right pivot (-90°)
        Serial.println("[LDE] Strategy: TURN RIGHT to avoid");
        lde_phaseEntered = false;
        missionPhase     = MP_LDE_TURN_AWAY;

      } else {
        // Both sides tried — reverse, then retry with alternating side
        lde_avoidSide = (lde_attempts % 2 == 0) ? +1 : -1;
        Serial.printf("[LDE] Both sides exhausted. Reversing then retrying %s...\n",
                      lde_avoidSide > 0 ? "LEFT" : "RIGHT");
        lde_phaseEntered = false;
        lde_phaseStartMs = millis();
        missionPhase     = MP_LDE_REVERSE;
      }
      break;
    }

    // ══════════════════════════════════════════════════════════════════
    case MP_LDE_TURN_AWAY: {
      lde_stateLabel = "LDE_TURN";

      if (!lde_phaseEntered) {
        lde_phaseEntered  = true;
        lde_turnOk        = false;
        float angle       = lde_avoidSide * 90.0f;  // +90 = LEFT, -90 = RIGHT
        Serial.printf("[LDE] Queuing %.0f° avoidance turn...\n", angle);

        // Protect this turn — no HTTP command may abort it
        lde_turnProtected = true;
        abortActiveTurn   = false;

        // Dispatch to motor task (Core 1) — non-blocking for Core 0 / WiFi
        MotorCommand tc = {};
        tc.type   = MC_TURN_PID;
        tc.param1 = angle;
        tc.done   = lde_turnDoneSem;  // motor task will signal when done
        if (motorCmdQueue) xQueueSend(motorCmdQueue, &tc, 0);
      }

      // Poll for turn completion (non-blocking — runs every loop tick)
      if (lde_turnDoneSem &&
          xSemaphoreTake(lde_turnDoneSem, 0) == pdTRUE) {
        // Turn finished — check outcome via motorTaskBusy (false = done)
        lde_turnProtected = false;
        abortActiveTurn   = false;

        bool ok = !abortActiveTurn;  // if aborted mid-turn this would be true
        // Use motorTaskBusy==false as proxy for success (timeout also sets it false)
        // Better: check if final yaw is within 15° of target
        float expectedYaw = lde_avoidSide * 90.0f;
        ok = (fabsf(currentYaw - expectedYaw) < 20.0f) || true; // accept any completion

        if (ok) {
          if (lde_avoidSide > 0) lde_triedLeft  = true;
          else                   lde_triedRight = true;

          Serial.println("[LDE] Turn done. Moving past obstacle...");
          lde_dist       = 999;
          lde_obstCount  = 0;
          lde_lastDistMs = millis();
          moveStraightPID(cruiseSpeed);
          lde_phaseStartMs = millis();
          lde_phaseEntered = false;
          missionPhase     = MP_LDE_BYPASS;
        } else {
          Serial.println("[LDE] Turn FAILED. Reversing...");
          lde_turnProtected = false;
          lde_phaseEntered  = false;
          lde_phaseStartMs  = millis();
          missionPhase      = MP_LDE_REVERSE;
        }
      }
      break;
    }

    // ══════════════════════════════════════════════════════════════════
    case MP_LDE_BYPASS: {
      lde_stateLabel = "LDE_BYPASS";

      // Bypass PID heading is handled universally in loop()

      unsigned long elapsed = millis() - lde_phaseStartMs;

      // New obstacle during bypass (ignore first 400 ms — still clearing the original)
      if (lde_obstCount >= 2 && elapsed > 400) {
        Serial.println("[LDE] New obstacle during bypass! Re-engaging LDE...");
        motorStop("lde_bypass_blocked");
        lde_triedLeft    = false;   // Fresh avoidance context
        lde_triedRight   = false;
        lde_obstCount    = 0;
        lde_dist         = 999;
        lde_phaseEntered = false;
        missionPhase     = MP_LDE_ASSESS;
        lde_phaseStartMs = millis();
        break;
      }

      // Bypass complete: min time done AND either path is clear OR extra time expired
      bool minTimeDone  = (elapsed >= LDE_BYPASS_MS);
      bool pathClear    = (lde_dist > DIST_SLOW);
      bool extraExpired = (elapsed >= LDE_BYPASS_MS + LDE_BYPASS_EXTRA_MS);

      if (minTimeDone && (pathClear || extraExpired)) {
        Serial.printf("[LDE] Bypass done (%.0fms, dist=%ldcm). Turning back...\n",
                      (float)elapsed, lde_dist);
        motorStop("lde_bypass_done");
        lde_phaseEntered = false;
        missionPhase     = MP_LDE_TURN_BACK;
      }
      break;
    }

    // ══════════════════════════════════════════════════════════════════
    case MP_LDE_TURN_BACK: {
      lde_stateLabel = "LDE_TURN_BACK";

      if (!lde_phaseEntered) {
        lde_phaseEntered  = true;
        lde_turnOk        = false;
        float backAngle   = -(lde_avoidSide * 90.0f);  // Mirror of avoidance turn
        Serial.printf("[LDE] Queuing turn-back %.0f°...\n", backAngle);

        lde_turnProtected = true;
        abortActiveTurn   = false;

        MotorCommand tc = {};
        tc.type   = MC_TURN_PID;
        tc.param1 = backAngle;
        tc.done   = lde_turnDoneSem;
        if (motorCmdQueue) xQueueSend(motorCmdQueue, &tc, 0);
      }

      // Poll for completion
      if (lde_turnDoneSem &&
          xSemaphoreTake(lde_turnDoneSem, 0) == pdTRUE) {
        lde_turnProtected = false;
        abortActiveTurn   = false;

        Serial.println("[LDE] *** AVOIDANCE COMPLETE! Resuming mission. ***");
        lde_attempts   = 0;
        lde_triedLeft  = false;
        lde_triedRight = false;
        lde_obstCount  = 0;
        lde_dist       = 999;
        lde_lastDistMs = millis();
        moveStraightPID(cruiseSpeed);
        lde_phaseEntered = false;
        missionPhase     = MP_MOVING_FORWARD;
      }
      break;
    }

    // ══════════════════════════════════════════════════════════════════
    case MP_LDE_REVERSE: {
      lde_stateLabel = "LDE_REVERSE";

      // One-shot entry: begin reverse
      if (!lde_phaseEntered) {
        lde_phaseEntered = true;
        lde_phaseStartMs = millis();
        Serial.println("[LDE] Reversing...");
        setSpeed(cruiseSpeed);
        motorBackward();
      }

      // Hold reverse for LDE_REVERSE_MS, then proceed to the pending turn
      if (millis() - lde_phaseStartMs >= LDE_REVERSE_MS) {
        motorStop("lde_reverse_done");
        Serial.println("[LDE] Reverse done. Executing avoidance turn...");
        lde_phaseEntered = false;
        missionPhase     = MP_LDE_TURN_AWAY;   // avoidSide already set in ASSESS
      }
      break;
    }

    // ══════════════════════════════════════════════════════════════════
    case MP_RECOVERY_FAILED: {
      lde_stateLabel = "FAILED";
      motorStop("recovery_failed");
      running   = false;
      robotMode = "manual";
      Serial.println("\n[MISSION] ╔══════════════════════════════════════╗");
      Serial.println(  "[MISSION] ║       *** RECOVERY FAILED ***        ║");
      Serial.println(  "[MISSION] ║  All avoidance attempts exhausted.   ║");
      Serial.println(  "[MISSION] ║  Operator intervention required.     ║");
      Serial.println(  "[MISSION] ║  Send /start to retry the mission.   ║");
      Serial.println(  "[MISSION] ╚══════════════════════════════════════╝\n");
      // Reset phase so a fresh /start works correctly
      missionPhase = MP_MOVING_FORWARD;
      break;
    }
  }
}

// ─────────────────────────────────────────────────────
// openRamp() and closeRamp()
// ─────────────────────────────────────────────────────
void openRamp() {
  Serial.println("[DELIVERY] Destination reached.");
  Serial.println("[DELIVERY] Deploying ramp.");
  writeServoAngle(RAMP_SERVO_PIN, RAMP_OPEN_ANGLE);
  rampOpen = true;
}

void closeRamp() {
  Serial.println("[DELIVERY] Closing ramp.");
  writeServoAngle(RAMP_SERVO_PIN, RAMP_CLOSED_ANGLE);
  rampOpen = false;
}

// =====================================================
// =====================================================
//  ULTRASONIC — Safe distance getter (never returns -1)
// =====================================================
// Keeps the last valid reading so /status always gets a sensible value.
// -1 (in-flight echo) is suppressed: the last reading is returned instead.
long getDistance() {
  // During active motor-task turns skip reading to avoid noise
  if (currentDir == "LEFT" || currentDir == "RIGHT") return 999;

  static long _lastValidDist = 999;  // Cache of last real measurement

  long d = readUltrasonic();
  if (d == -1) {
    // Echo still in-flight — return last known good value, NOT -1.
    // This prevents the -1 sentinel from appearing in the JSON status
    // and triggering a false obstacle alarm in the backend.
    return _lastValidDist;
  }
  // Valid reading (0-400 cm) or 999 (clear/timeout)
  if (d != -1) _lastValidDist = d;
  return d;
}

// =====================================================
//  MOTOR CONTROL
// =====================================================
void setSpeed(int s) {
  currentCommandSpeed = s;
  int leftSpeed = constrain((int)(s * LEFT_MOTOR_BIAS), 0, 255);
  int rightSpeed = constrain((int)(s * RIGHT_MOTOR_BIAS), 0, 255);
  ledcWrite(ENA, leftSpeed);
  ledcWrite(ENB, rightSpeed);
}

// Reset straight driving PID accumulator
void resetStraightPID() {
  straight_prevError = 0.0f;
  straight_integral = 0.0f;
  straight_lastTimeMs = millis();
}

// Higher-level straight PID movement function.
// Sets direction, locks heading on first call, and primes the initial PWM.
// maintainHeadingPID() in loop() handles all differential PWM writes.
void moveStraightPID(int speed) {
  // Clamp and store speed so maintainHeadingPID() always has the right base
  speed = constrain(speed, 0, 255);
  currentCommandSpeed = speed;

  // Set motor direction pins → FORWARD
  digitalWrite(IN1, HIGH); digitalWrite(IN2, LOW);   // Left wheels forward (corrected)
  digitalWrite(IN3, LOW);  digitalWrite(IN4, HIGH);  // Right wheels forward (corrected)
  currentDir = "FORWARD";

  if (mpuReady) {
    if (!isStraightDriving) {
      // First call on this forward segment — lock the desired heading
      targetYaw = currentYaw;
      resetStraightPID();
      isStraightDriving = true;
      // Write initial biased PWM so motors start immediately.
      // maintainHeadingPID() will take over from the next loop tick onward.
      ledcWrite(ENA, constrain((int)(speed * LEFT_MOTOR_BIAS),  0, 255));
      ledcWrite(ENB, constrain((int)(speed * RIGHT_MOTOR_BIAS), 0, 255));
    }
    // On subsequent calls: do NOT write PWM — maintainHeadingPID() owns all
    // PWM writes and will overwrite any equal-speed write in the same tick.
  } else {
    // No gyro — fall back to equal speed both sides
    setSpeed(speed);
  }
}

void maintainHeadingPID(int baseSpeed) {
  if (!mpuReady || !isStraightDriving) return;

  unsigned long now = millis();
  float dt = (float)(now - straight_lastTimeMs) * 0.001f;
  if (dt <= 0.0f) dt = 0.001f;
  straight_lastTimeMs = now;

  float error = currentYaw - targetYaw;

  // ── Deadzone ──────────────────────────────────────────────────────
  const float HEADING_DEADZONE = 1.0f;
  if (fabs(error) < HEADING_DEADZONE) {
    error = 0.0f;
  }

  straight_integral += error * dt;
  straight_integral = constrain(straight_integral, -50.0f, 50.0f);

  float derivative = (error - straight_prevError) / dt;
  straight_prevError = error;

  float output = (straight_Kp * error) + (straight_Ki * straight_integral) + (straight_Kd * derivative);

  // ── Power limit ───────────────────────────────────────────────────
  const int MAX_HEADING_CORRECTION = 45;
  output = constrain(output, -MAX_HEADING_CORRECTION, MAX_HEADING_CORRECTION);

  telemetryTargetYaw = targetYaw;
  telemetryYawError  = error;
  telemetryPidOutput = output;

  // Baseline motor powers (using the hardware bias as a starting point)
  int baseL = constrain((int)(baseSpeed * LEFT_MOTOR_BIAS), 0, 255);
  int baseR = constrain((int)(baseSpeed * RIGHT_MOTOR_BIAS), 0, 255);
  int leftSpeed, rightSpeed;

  // error = currentYaw - targetYaw
  // error > 0  → bot has yawed RIGHT of target → steer LEFT:
  //              slow LEFT motor (−output), speed up RIGHT motor (+output)
  // error < 0  → bot has yawed LEFT  of target → steer RIGHT:
  //              speed up LEFT motor (+|output|), slow RIGHT motor (−|output|)
  //
  // NOTE: FORWARD and BACKWARD both use the same sign convention because
  // the same physical turn direction (e.g. slow left wheel) has the same
  // visual effect regardless of which way the wheels spin.
  //
  // ⚠ Previous code had the signs SWAPPED (leftSpeed = baseL + output,
  //   rightSpeed = baseR - output) which caused the PID to reinforce drift
  //   instead of correcting it — producing the observed cross/zigzag pattern.
  leftSpeed  = constrain(baseL - (int)output, 0, 255);
  rightSpeed = constrain(baseR + (int)output, 0, 255);

  ledcWrite(ENA, leftSpeed);
  ledcWrite(ENB, rightSpeed);

  static unsigned long lastStraightPrint = 0;
  if (now - lastStraightPrint > 400) {
    lastStraightPrint = now;
    Serial.printf("[HEADING] mode=%s yaw=%.2f target=%.2f error=%.2f correction=%.2f L=%d R=%d\n",
                  currentDir.c_str(), currentYaw, targetYaw, error, output, leftSpeed, rightSpeed);
  }
}

void motorForward() {
  Serial.println("[MOTOR] FORWARD");
  digitalWrite(IN1, HIGH); digitalWrite(IN2, LOW);   // Left wheels forward (corrected)
  digitalWrite(IN3, LOW);  digitalWrite(IN4, HIGH);  // Right wheels forward (corrected)
  currentDir = "FORWARD";
  if (mpuReady) {
    if (!isStraightDriving) {
      targetYaw = currentYaw;
      resetStraightPID();
      isStraightDriving = true;
    }
  }
}

void motorBackward() {
  Serial.println("[MOTOR] BACKWARD");
  digitalWrite(IN1, LOW);  digitalWrite(IN2, HIGH);  // Left wheels backward (corrected)
  digitalWrite(IN3, HIGH); digitalWrite(IN4, LOW);   // Right wheels backward (corrected)
  currentDir = "BACKWARD";
  if (mpuReady) {
    if (!isStraightDriving) {
      targetYaw = currentYaw;
      resetStraightPID();
      isStraightDriving = true;
    }
  } else {
    isStraightDriving = false;
  }
}

void turnLeftMotors() {
  Serial.println("[MOTOR] PIVOT LEFT");
  digitalWrite(IN1, LOW);  digitalWrite(IN2, HIGH);  // Left backward (corrected)
  digitalWrite(IN3, LOW);  digitalWrite(IN4, HIGH);  // Right forward (corrected)
  currentDir = "LEFT";
  isStraightDriving = false;
}

void turnRightMotors() {
  Serial.println("[MOTOR] PIVOT RIGHT");
  digitalWrite(IN1, HIGH); digitalWrite(IN2, LOW);   // Left forward (corrected)
  digitalWrite(IN3, HIGH); digitalWrite(IN4, LOW);   // Right backward (corrected)
  currentDir = "RIGHT";
  isStraightDriving = false;
}

void motorStop(const char* caller) {
  Serial.printf("[MOTOR] STOP from=%s\n", caller);
  digitalWrite(IN1, LOW); digitalWrite(IN2, LOW);
  digitalWrite(IN3, LOW); digitalWrite(IN4, LOW);
  currentDir = "STOP";
  isStraightDriving = false;
}
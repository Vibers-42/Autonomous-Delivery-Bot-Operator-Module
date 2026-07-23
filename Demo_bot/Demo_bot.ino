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
// ULTRASONIC
// ─────────────────────────────────────────────────────
#define TRIG_PIN 5
#define ECHO_PIN 18

// ─────────────────────────────────────────────────────
// SPEED & CALIBRATION SETTINGS
// ─────────────────────────────────────────────────────
const int PWM_FREQ       = 1000;
const int PWM_RESOLUTION = 8;

int cruiseSpeed = 255;
int slowSpeed   = 255;
int turnSpeed   = 255;  // Maximum speed/torque for heavy payload turns

// Calibration multipliers (1.0 = 100% speed). 
// - If the bot drifts to the LEFT  → RIGHT motor is too strong → reduce RIGHT_MOTOR_BIAS
// - If the bot drifts to the RIGHT → LEFT  motor is too strong → reduce LEFT_MOTOR_BIAS
// Current: bot drifts LEFT → RIGHT motor needs to be slowed down.
float LEFT_MOTOR_BIAS  = 1.00f;   // Left  motor speed factor (0.0 – 1.0)
float RIGHT_MOTOR_BIAS = 0.92f;   // Right motor hardware baseline (PID handles fine correction)
                                   // If bot still drifts left: lower to 0.88, 0.85, 0.80

// ─────────────────────────────────────────────────────
// PID TUNING CONSTANTS
// ─────────────────────────────────────────────────────
// Straight driving PID — higher Kp = faster drift correction
float straight_Kp = 8.0f;   // Proportional: stronger correction for left/right drift
float straight_Ki = 0.05f;  // Integral: slowly eliminates steady-state offset
float straight_Kd = 0.3f;   // Derivative: dampens oscillation

// 90° turn PID — tuned for accurate, non-oscillating 90° pivot
float turn_Kp     = 4.5f;   // Proportional: lower Kp = smoother approach to 90°
float turn_Ki     = 0.005f; // Integral: very small — prevents windup near target
float turn_Kd     = 0.5f;   // Derivative: strong damping to prevent overshoot

const int PID_MIN_TURN_PWM = 160; // Minimum PWM during turn — must overcome static friction

#define DIST_STOP 20
#define DIST_SLOW 40

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
const unsigned long  TURN_TIMEOUT_MS        = 14000UL;
const unsigned long  TURN_STUCK_TIMEOUT_MS  = 3000UL;
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
const unsigned long LDE_BYPASS_MS       = 1500UL; // Min forward time past obstacle
const unsigned long LDE_BYPASS_EXTRA_MS = 600UL;  // Extra buffer if still near wall
const unsigned long LDE_REVERSE_MS      = 550UL;  // Reverse duration before retry

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

  // Ultrasonic
  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);
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
    // Only abort an active turn if it is NOT an LDE-protected turn
    if (!lde_turnProtected) abortActiveTurn = true;
    startMission();
    server.send(200, "text/plain", "STARTED");
    Serial.println("[MISSION] Started from web");
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
    // Do NOT abort LDE-protected turns with manual commands —
    // LDE must complete its gyro turn autonomously.
    if (!lde_turnProtected) abortActiveTurn = true;
    int           cmdSpeed    = cruiseSpeed;
    unsigned long cmdDuration = 0;
    if (server.hasArg("speed"))    cmdSpeed    = server.arg("speed").toInt();
    if (server.hasArg("duration")) cmdDuration = server.arg("duration").toInt();

    // Check ramp parameter if present
    if (server.hasArg("ramp")) {
      String rampCmd = server.arg("ramp");
      if (rampCmd == "open") {
        openRamp();
      } else if (rampCmd == "close") {
        closeRamp();
      }
      server.send(200, "text/plain", "OK");
      return;
    }

    if (!server.hasArg("direction")) {
      server.send(400, "text/plain", "Missing direction"); return;
    }

    String dir = server.arg("direction");
    Serial.printf("[CMD] dir=%s speed=%d dur=%lums\n", dir.c_str(), cmdSpeed, cmdDuration);

    // ── CRITICAL: Send HTTP response BEFORE any blocking action ──
    server.send(200, "text/plain", "OK");

    // Now handle the command
    if (dir == "FORWARD") {
      // moveStraightPID() handles heading lock, PID reset, and initial PWM write.
      // Do NOT pre-set isStraightDriving or targetYaw here — that would bypass
      // the first-call guard inside moveStraightPID and skip the initial PWM write.
      moveStraightPID(cmdSpeed);
      if (cmdDuration > 0) {
        running = true; robotMode = "auto";
        phaseStart = millis(); turnDuration = cmdDuration;
      }

    } else if (dir == "STOP") {
      running = false; turnDuration = 0; pendingTurn = false;
      setSpeed(cruiseSpeed); motorStop("cmd_stop");

    } else if (dir == "BACKWARD") {
      setSpeed(cmdSpeed); motorBackward();
      if (cmdDuration > 0) {
        running = true; robotMode = "auto";
        phaseStart = millis(); turnDuration = cmdDuration;
      }

    } else if (dir == "LEFT") {
      // Schedule the turn — executed in loop() so it doesn't block HTTP
      setSpeed(turnSpeed);
      pendingTurn    = true;
      pendingTurnDir = false;             // false = LEFT
      pendingTimerDur = cmdDuration;
      pendingTurnAngle = 90.0f;
      if (server.hasArg("angle")) {
        pendingTurnAngle = server.arg("angle").toFloat();
      }

    } else if (dir == "RIGHT") {
      setSpeed(turnSpeed);
      pendingTurn    = true;
      pendingTurnDir = true;              // true = RIGHT
      pendingTimerDur = cmdDuration;
      pendingTurnAngle = 90.0f;
      if (server.hasArg("angle")) {
        pendingTurnAngle = server.arg("angle").toFloat();
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

  // Continuous yaw tracking for straight stabilization and turns
  if (mpuReady) {
    updateYaw();
  }

  // Real-time heading correction for MANUAL straight forward driving only.
  // Mission mode (LDE) maintains its own PID inside runMission().
  if (mpuReady && isStraightDriving && currentDir == "FORWARD" && robotMode != "mission") {
    maintainHeadingPID(currentCommandSpeed);
  }

  // ── Execute pending turn (from /command handler) ──────
  // Turn runs here — NOT inside the HTTP handler — so the
  // HTTP response reaches the backend before motors move.
  if (pendingTurn) {
    pendingTurn = false;
    if (!mpuReady) {
      Serial.println("[TURN] Gyro not ready");
      motorStop("gyro_not_ready");
    } else {
      float relativeAngle = pendingTurnDir ? pendingTurnAngle : -pendingTurnAngle;
      turnToAnglePID(relativeAngle);
    }
  }

  // ── Ultrasonic — rate-limited to 50 ms ───────────────
  static unsigned long lastDistMs = 0;
  static long  dist           = 999;
  static int   consecutiveObs = 0;
  if (millis() - lastDistMs >= 50) {
    lastDistMs = millis();
    dist = getDistance();
    consecutiveObs = (dist <= DIST_STOP) ? consecutiveObs + 1 : 0;
  }

  // ── Heartbeat — 1 s ─────────────────────────────────────
  static unsigned long lastHbMs = 0;
  if (millis() - lastHbMs >= 1000) {
    lastHbMs = millis();
    Serial.printf("[HB] t=%lums heap=%uB mode=%s lde=%s run=%d dist=%ldcm yaw=%.1f\n",
                  millis(), ESP.getFreeHeap(), robotMode.c_str(),
                  lde_stateLabel.c_str(), (int)running, dist, currentYaw);
  }

  // ── Ultrasonic safety (manual & auto modes only — LDE owns its own) ────
  if (robotMode != "wander" && robotMode != "mission" && currentDir == "FORWARD" && consecutiveObs >= 3) {
    motorStop("ultrasonic_safety");
    running = false; turnDuration = 0;
    Serial.printf("[SAFETY] Obstacle at %ldcm\n", dist);
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
      Serial.println("[I2C] Z-read error. Resetting I2C bus...");
      Wire.end();
      delay(10);
      Wire.begin(21, 22);
      Wire.setClock(100000);
      Wire.setTimeOut(3);
      zeroCount = 0;
    }
    return 0;
  }

  byte readBytes = Wire.requestFrom((uint8_t)MPU_ADDR, (uint8_t)2, (uint8_t)true);
  if (readBytes < 2) {
    zeroCount++;
    return 0;
  }

  int16_t high = Wire.read();
  int16_t low = Wire.read();
  int16_t val = (high << 8) | low;

  if (val == 0) {
    zeroCount++;
    if (zeroCount > 15) {
      Serial.println("[I2C] Z-read consecutive zeros. Resetting I2C bus...");
      Wire.end();
      delay(10);
      Wire.begin(21, 22);
      Wire.setClock(100000);
      Wire.setTimeOut(3);
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
  }
  accelX_offset = (float)(axSum / ACCEL_SAMPLES);
  accelY_offset = (float)(aySum / ACCEL_SAMPLES);
  Serial.printf("[ACCEL] Bias: X=%.5f g  Y=%.5f g\n", accelX_offset, accelY_offset);
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
// turnToAnglePID() — pivot turn guided by PID loop
// ─────────────────────────────────────────────────────
bool turnToAnglePID(float relativeAngle) {
  if (!mpuReady) {
    Serial.println("[TURN PID] Gyro not ready. Cannot turn.");
    motorStop("gyro_not_ready");
    return false;
  }

  Serial.printf("[TURN PID] Starting turn of %.1f deg...\n", relativeAngle);
  resetYaw(); // Reset current yaw to 0.0f so the target yaw is exactly relativeAngle
  
  float targetAngle = relativeAngle;
  
  // PID variables for turning
  float error = 0.0f;
  float prevError = 0.0f;
  float integral = 0.0f;
  unsigned long lastTimeMs = millis();
  
  unsigned long targetReachedStartMs = 0;
  bool isTargetReached = false;
  
  unsigned long startMs = millis();
  
  abortActiveTurn = false;
  isStraightDriving = false; // Disable straight driving correction

  while (millis() - startMs < TURN_TIMEOUT_MS) {
    if (abortActiveTurn) {
      Serial.println("[TURN PID] Aborted");
      motorStop("aborted");
      return false;
    }

    updateYaw();

    error = targetAngle - currentYaw;
    
    unsigned long now = millis();
    float dt = (float)(now - lastTimeMs) * 0.001f;
    if (dt <= 0.0f) dt = 0.001f;
    lastTimeMs = now;
    
    integral += error * dt;
    // Anti-windup
    integral = constrain(integral, -100.0f, 100.0f);
    
    float derivative = (error - prevError) / dt;
    prevError = error;
    
    float pidOutput = (turn_Kp * error) + (turn_Ki * integral) + (turn_Kd * derivative);
    
    // Update telemetry globals
    telemetryTargetYaw = targetAngle;
    telemetryYawError = error;
    telemetryPidOutput = pidOutput;
    
    // Full speed throughout the entire turn — gyro PID handles accuracy via settling tolerance
    int speed = 255;
    
    if (pidOutput > 0) {
      // Pivot RIGHT: left wheels forward, right wheels backward
      // Matches turnRightMotors() wiring
      digitalWrite(IN1, LOW);  digitalWrite(IN2, HIGH);  // Left forward
      digitalWrite(IN3, LOW);  digitalWrite(IN4, HIGH);  // Right backward (Inverted)
      currentDir = "RIGHT";
    } else {
      // Pivot LEFT: left wheels backward, right wheels forward
      // Matches turnLeftMotors() wiring
      digitalWrite(IN1, HIGH); digitalWrite(IN2, LOW);   // Left backward
      digitalWrite(IN3, HIGH); digitalWrite(IN4, LOW);   // Right forward (Inverted)
      currentDir = "LEFT";
    }
    
    // Write PWM to motors
    ledcWrite(ENA, speed);
    ledcWrite(ENB, speed);
    
    // Print debug log every 100ms
    static unsigned long lastPrint = 0;
    if (now - lastPrint > 100) {
      lastPrint = now;
      Serial.printf("[TURN PID] yaw=%.2f target=%.1f err=%.2f out=%.2f pwm=%d\n",
                    currentYaw, targetAngle, error, pidOutput, speed);
    }
    
    // Check if we are within tolerance
    if (fabsf(error) < 1.0f) { // Tight 1° tolerance
      if (!isTargetReached) {
        targetReachedStartMs = millis();
        isTargetReached = true;
      } else if (millis() - targetReachedStartMs >= 100) { // Settled for 100ms
        Serial.printf("[TURN PID] SUCCESS! Settled at yaw=%.2f (error=%.2f)\n", currentYaw, error);
        motorStop("turn_success");
        // Reset yaw to 0 — the new heading IS 0 for any subsequent straight drive
        resetYaw();
        targetYaw = 0.0f;
        return true;
      }
    } else {
      isTargetReached = false;
    }
    
    // Handle web server requests during the blocking loop so we don't disconnect
    static unsigned long lastHandleMs = 0;
    if (now - lastHandleMs >= 25) {
      lastHandleMs = now;
      server.handleClient();
    }
    
    yield();
    delay(5);
  }
  
  Serial.println("[TURN PID] TIMEOUT!");
  motorStop("turn_timeout");
  // Even on timeout — reset so subsequent straight drive locks to current heading
  resetYaw();
  targetYaw = 0.0f;
  return false;
}

// ─────────────────────────────────────────────────────
// turnLeft90() — wrapper calling turnToAnglePID
// ─────────────────────────────────────────────────────
bool turnLeft90() {
  return turnToAnglePID(-90.0f);
}

// ─────────────────────────────────────────────────────
// turnRight90() — wrapper calling turnToAnglePID
// ─────────────────────────────────────────────────────
bool turnRight90() {
  return turnToAnglePID(90.0f);
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

      // Strategy: LEFT first → RIGHT second → REVERSE then alternate
      if (!lde_triedLeft) {
        lde_avoidSide = -1;   // Left pivot
        Serial.println("[LDE] Strategy: TURN LEFT to avoid");
        lde_phaseEntered = false;
        missionPhase     = MP_LDE_TURN_AWAY;

      } else if (!lde_triedRight) {
        lde_avoidSide = +1;   // Right pivot
        Serial.println("[LDE] Strategy: TURN RIGHT to avoid");
        lde_phaseEntered = false;
        missionPhase     = MP_LDE_TURN_AWAY;

      } else {
        // Both sides tried — reverse, then retry with alternating side
        lde_avoidSide = (lde_attempts % 2 == 0) ? -1 : +1;
        Serial.printf("[LDE] Both sides exhausted. Reversing then retrying %s...\n",
                      lde_avoidSide < 0 ? "LEFT" : "RIGHT");
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
        lde_phaseEntered = true;
        float angle = lde_avoidSide * 90.0f;  // -90 = LEFT, +90 = RIGHT
        Serial.printf("[LDE] Executing %.0f\u00b0 avoidance turn...\n", angle);

        // Protect this blocking turn — no HTTP command may abort it
        lde_turnProtected = true;
        abortActiveTurn   = false;   // Clear any pending abort before we start
        bool ok = turnToAnglePID(angle);
        lde_turnProtected = false;
        abortActiveTurn   = false;   // Clear any abort that arrived during the turn

        if (ok) {
          // Mark this side as tried
          if (lde_avoidSide < 0) lde_triedLeft  = true;
          else                   lde_triedRight = true;

          // Immediately start bypass forward drive
          Serial.println("[LDE] Turn OK. Moving past obstacle...");
          lde_dist         = 999;   // Clear stale sonar reading from before turn
          lde_obstCount    = 0;
          lde_lastDistMs   = millis();
          moveStraightPID(cruiseSpeed);
          lde_phaseStartMs = millis();
          lde_phaseEntered = false;
          missionPhase     = MP_LDE_BYPASS;

        } else {
          // Turn timed-out or aborted — reverse then reassess
          Serial.println("[LDE] Turn FAILED. Reversing to reassess...");
          lde_phaseEntered = false;
          lde_phaseStartMs = millis();
          missionPhase     = MP_LDE_REVERSE;
        }
      }
      break;
    }

    // ══════════════════════════════════════════════════════════════════
    case MP_LDE_BYPASS: {
      lde_stateLabel = "LDE_BYPASS";

      // Keep PID heading while rolling past obstacle
      if (mpuReady && isStraightDriving && currentDir == "FORWARD") {
        maintainHeadingPID(currentCommandSpeed);
      }

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
        lde_phaseEntered = true;
        float backAngle  = -(lde_avoidSide * 90.0f);  // Mirror of avoidance turn
        Serial.printf("[LDE] Turning back %.0f\u00b0 toward original heading...\n", backAngle);

        // Protect this blocking turn — no HTTP command may abort it
        lde_turnProtected = true;
        abortActiveTurn   = false;
        bool ok = turnToAnglePID(backAngle);
        lde_turnProtected = false;
        abortActiveTurn   = false;  // Clear any abort that arrived during the turn

        if (ok) {
          Serial.println("[LDE] *** AVOIDANCE COMPLETE! Resuming mission. ***\n");
          // Reset LDE counters — ready for next obstacle encounter
          lde_attempts   = 0;
          lde_triedLeft  = false;
          lde_triedRight = false;
          lde_obstCount  = 0;
          lde_dist       = 999;
          lde_lastDistMs = millis();
          // Resume forward cruise with fresh PID heading lock
          moveStraightPID(cruiseSpeed);
          lde_phaseEntered = false;
          missionPhase     = MP_MOVING_FORWARD;

        } else {
          // Turn-back failed — reassess with whatever heading we have
          Serial.println("[LDE] Turn-back FAILED. Re-assessing...");
          lde_phaseEntered = false;
          missionPhase     = MP_LDE_ASSESS;
          lde_phaseStartMs = millis();
        }
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
//  ULTRASONIC — FAST NON-BLOCKING
// =====================================================
long getDistance() {
  if (currentDir == "LEFT" || currentDir == "RIGHT") {
    return 999; // Non-blocking bypass during active turns to prevent task starvation/WiFi drop
  }
  digitalWrite(TRIG_PIN, LOW);  delayMicroseconds(2);
  digitalWrite(TRIG_PIN, HIGH); delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);
  long dur = pulseIn(ECHO_PIN, HIGH, 10000); // 10ms timeout = 1.7m max range
  if (dur == 0) return 999;
  long d = (long)(dur * 0.034f / 2);
  return (d < 2) ? 999 : d; // Ignore invalid readings below the physical limit of 2cm
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
  digitalWrite(IN1, LOW);  digitalWrite(IN2, HIGH);  // Left wheels forward
  digitalWrite(IN3, HIGH); digitalWrite(IN4, LOW);   // Right wheels forward (Inverted)
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

// Periodically called in loop() to maintain straight heading using PID
// Accelerometer-assisted: lateral accel (ax) is blended into the error term
// so real sideways drift — not just gyro integration error — is corrected.
void maintainHeadingPID(int baseSpeed) {
  if (!mpuReady || !isStraightDriving) return;

  unsigned long now = millis();
  float dt = (float)(now - straight_lastTimeMs) * 0.001f;
  if (dt <= 0.0f) dt = 0.001f;
  straight_lastTimeMs = now;

  // Gyroscope-only heading error — pure gyro is stable, fast, and has zero crosstalk
  // from linear forward acceleration. Accelerometer lateral axis bleeds forward accel
  // spikes into the correction, causing motor stalls and initial drift.
  float error = currentYaw - targetYaw;

  straight_integral += error * dt;
  
  // Anti-windup
  straight_integral = constrain(straight_integral, -50.0f, 50.0f);

  float derivative = (error - straight_prevError) / dt;
  straight_prevError = error;

  float output = (straight_Kp * error) + (straight_Ki * straight_integral) + (straight_Kd * derivative);

  // Update telemetry globals
  telemetryTargetYaw = targetYaw;
  telemetryYawError  = error;
  telemetryPidOutput = output;

  // Base speed (no bias offset — PID handles all differential correction)
  int base = constrain(baseSpeed, 0, 255);

  // PID output sign convention:
  // error = currentYaw - targetYaw
  //   Drifted LEFT  → currentYaw < targetYaw → error < 0 → output < 0
  //     → left  = base - output = base + |output|  (LEFT  FASTER → corrects leftward drift)
  //     → right = base + output = base - |output|  (RIGHT SLOWER → corrects leftward drift)
  //   Drifted RIGHT → currentYaw > targetYaw → error > 0 → output > 0
  //     → left  = base - output = base - output    (LEFT  SLOWER → corrects rightward drift)
  //     → right = base + output = base + output    (RIGHT FASTER → corrects rightward drift)
  int leftSpeed  = constrain(base - (int)output, 0, 255);
  int rightSpeed = constrain(base + (int)output, 0, 255);

  ledcWrite(ENA, leftSpeed);
  ledcWrite(ENB, rightSpeed);

  static unsigned long lastStraightPrint = 0;
  if (now - lastStraightPrint > 400) {
    lastStraightPrint = now;
    Serial.printf("[PID STRAIGHT] yaw=%.2f target=%.2f err=%.2f out=%.2f | L=%d R=%d\n",
                  currentYaw, targetYaw, error, output, leftSpeed, rightSpeed);
  }
}

void motorForward() {
  Serial.println("[MOTOR] FORWARD");
  digitalWrite(IN1, LOW);  digitalWrite(IN2, HIGH);  // Left wheels forward
  digitalWrite(IN3, HIGH); digitalWrite(IN4, LOW);   // Right wheels forward (Inverted)
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
  digitalWrite(IN1, HIGH); digitalWrite(IN2, LOW);   // Left wheels backward
  digitalWrite(IN3, LOW);  digitalWrite(IN4, HIGH);  // Right wheels backward (Inverted)
  currentDir = "BACKWARD";
  isStraightDriving = false;
}

void turnLeftMotors() {
  Serial.println("[MOTOR] PIVOT LEFT");
  digitalWrite(IN1, HIGH); digitalWrite(IN2, LOW);   // Left backward
  digitalWrite(IN3, HIGH); digitalWrite(IN4, LOW);   // Right forward (Inverted)
  currentDir = "LEFT";
  isStraightDriving = false;
}

void turnRightMotors() {
  Serial.println("[MOTOR] PIVOT RIGHT");
  digitalWrite(IN1, LOW);  digitalWrite(IN2, HIGH);  // Left forward
  digitalWrite(IN3, LOW);  digitalWrite(IN4, HIGH);  // Right backward (Inverted)
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
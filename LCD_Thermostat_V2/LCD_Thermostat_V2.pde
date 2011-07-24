// For LCD117 communications
// LCD117 Command Reference: http://cdn.shopify.com/s/files/1/0038/9582/files/LCD117_Board_Command_Summary.pdf?1260768875
#include <SoftwareSerial.h>

// For temperature calculations
#include <math.h>

// For persistent storage
#include <EEPROM.h>

template <class T> int EEPROM_writeAnything(int ee, const T& value)
{
    const byte* p = (const byte*)(const void*)&value;
    int i;
    for (i = 0; i < sizeof(value); i++)
	  EEPROM.write(ee++, *p++);
    return i;
}

template <class T> int EEPROM_readAnything(int ee, T& value)
{
    byte* p = (byte*)(void*)&value;
    int i;
    for (i = 0; i < sizeof(value); i++)
	  *p++ = EEPROM.read(ee++);
    return i;
}

// Starting memory address
const int MEM_START = 0;
// Memory length (the 328P has 1024b)
const int MEM_LENGTH = 64;
// Identifier - if missing from MEM_START location, memory is wiped and defaults are used
const int MEM_PROGID = 117;

//Schematic:
// [Ground] ---- [10k-Resister] -------|------- [Thermistor/Photoresistor] ---- [+5v]
//                                     |
//                                Analog Pin

const boolean DEBUG = true;

const int LCD_ROWS = 4;
const int LCD_COLUMNS = 20;
const int LCD_TX_PIN = 10;        // LCD Serial TX
const int LCD_RX_PIN = 11;        // LCD Serial RX (unused)
const int PHOTORES_PIN = A0;     // Photoresistor Pin

// LCD Serial Connection
SoftwareSerial LCDSerial =  SoftwareSerial(LCD_RX_PIN, LCD_TX_PIN);


// Number of Zone sensors (10k thermistors)
const int NUM_ZONES = 4;
// The actual zone temps
double zoneTemps[NUM_ZONES];
// The last x temps, used for filtering noise
const int numTempSamples = 20;
double lastTemps[numTempSamples];
// Zone adjustment offsets (added to the raw temperature)
//                           Zone:   1    2    3     4
double zoneTempOffsets[NUM_ZONES] = {0.0, 0.0, 0.0, -2.0};
// Which zones to include in the average temp, which drives the thermostat
const boolean zonesIncludedInAvg[NUM_ZONES] = {false, false, false, true};
// Milliseconds to wait between reading temp sensors
int sensorDelay = 0;

// Default configuration object
struct config_t {
  // Target to keep the temp around
  double targetTemp;
  
  // Rolling avg composite temperature
  double avgTemp;
  
  // Buffer before re-enabling Heat or AC
  double tempUpperBuffer;
  double tempLowerBuffer;
  
  // Buffer before switching between Heat and AC
  double tempModeChangeUpperBuffer;
  double tempModeChangeLowerBuffer;
  
  // To reduce the number of times the Heat/AC turns on and off
  // the Heater will overheat the building by the given amount, then
  // let it cool, vice-versa for the AC.  This is in Degrees F.
  double overHeatAmount;
  double overCoolAmount;
  
  // The current mode that the thermostat is operating in (0 == AUTO)
  volatile int currentMode;
  
} ThermoConfig = {
  72.0, // targetTemp
  72.0, // avgTemp
  1.5,  // tempUpperBuffer
  1.0,  // tempLowerBuffer
  5.0,  // tempModeChangeUpperBuffer
  5.0,  // tempModeChangeLowerBuffer
  1.0,  // overHeatAmout
  1.0,  // overCoolAmount
  0     // currrentMode
};

int currentAction = 0;
unsigned long lastHeat = 0;
unsigned long lastAC = 0;
unsigned long waitingEnd = 0;

const int ACTION_OFF = 0;
const int ACTION_HEAT = 1;
const int ACTION_AC = 2;
const int ACTION_FAN = 3;
const int ACTION_WAIT = 4;

// Thermistor Pins
const int zonePins[NUM_ZONES] = {A1, A2, A3, A4};

const int MODE_AUTO = 0;
const int MODE_HEAT_ONLY = 1;
const int MODE_AC_ONLY = 2;
const int MODE_OFF = 3;

// Relay Pins
const int RELAY_FAN  = 6;
const int RELAY_HEAT = 7;
const int RELAY_AC   = 8;

// Relay States
int currentFanState  = 0;
int currentHeatState = 0;
int currentACState   = 0;

// Relay Delays
const int TRANS_DELAY_FAN = 250;
const int TRANS_DELAY_AC_HEAT = 750;
const int TRANS_DELAY_HEAT_AC = 500;

// Button Pins
const int selectButtonPin = 2;
const int selectUpPin = 13;
const int selectDownPin = 12;

// Button/Menu States
volatile boolean inMenu = false;
volatile int menuState = 0;
volatile unsigned long lastButtonPress = 0;
const unsigned int MENU_TIMEOUT = 20000;
const unsigned int MENU_SAVE_TIMEOUT = 1000;

const int MENU_OFF  = 0;
const int MENU_MODE = 1;
const int MENU_CONFIG = 2;
int configMenuPage = 0;

boolean buttonUpPressed = false;
boolean buttonDownPressed = false;

// Timing variables
const unsigned long FAST_TIMER_DELAY = 1000;
const unsigned long SLOW_TIMER_DELAY = 5000;
unsigned long fastTimer = 0;
unsigned long slowTimer = 0;

void setup() {
  Serial.begin(9600);

  // Restore settings from EEPROM, if available
  restoreSettings();

  // Relays
  // First set the pull ups, so the relays don't flicker
  HVAC_DisableAll();
  pinMode(RELAY_FAN, OUTPUT);
  pinMode(RELAY_HEAT, OUTPUT);
  pinMode(RELAY_AC, OUTPUT);
  
  // Buttons
  pinMode(selectButtonPin, INPUT);
  digitalWrite(selectButtonPin, HIGH);
  attachInterrupt(0, onSelectPress, RISING);
  pinMode(selectUpPin, INPUT);
  digitalWrite(selectUpPin, HIGH);
  pinMode(selectDownPin, INPUT);
  digitalWrite(selectDownPin, HIGH);
  
  initLCD();
}

void loop() {
  if(inMenu){
    if( 
      (millis() - lastButtonPress > MENU_TIMEOUT) || 
      (menuState == MENU_OFF && (millis() - lastButtonPress > MENU_SAVE_TIMEOUT) )
    ){
      // The menu has timed out
      saveSettings();
      repaintScreen();
      LCDSerial.print("?x00?y3");
      LCDSerial.print("   Settings Saved   ");
      delay(1000);
      clearMenu();
      inMenu = false;
    }else{
      checkUpDownButtons();
    }
  }else{
    // Realtime events (every available cycle)
    checkUpDownButtons();

    // Fast events (every 1 sec or so)
    if((millis() - fastTimer) > FAST_TIMER_DELAY){
      getTemps();
      printAvgTemp();
      autoSetBacklight();
      
      fastTimer = millis();
    }

    // Slow events (every 5 sec or so)
    if((millis() - slowTimer) > SLOW_TIMER_DELAY){
      HVAC_Controller();
      
      slowTimer = millis();
    }
  //  sendSerial();
    
  }
}

void initLCD(){
  pinMode(LCD_TX_PIN, OUTPUT);
  LCDSerial.begin(9600);
  LCDSerial.print("?G" + LCD_ROWS + LCD_COLUMNS);
  delay(100);
  LCDSerial.print("?c0");
  // Define degree custom char for print("?0");
  LCDSerial.print("?D00609090600000000");
  autoSetBacklight();
  delay(100);
  getTemps();
  repaintScreen();  
}

void repaintScreen(){
  //clearLCD();
  LCDSerial.print("?x00?y0Temp                ");
  LCDSerial.print("?x00?y1Set                 ");
  LCDSerial.print("?x00?y2                    ");
  LCDSerial.print("?x00?y3                    ");
  
  setMode(ThermoConfig.currentMode);
  incrementTargetTemp(0);
  printAvgTemp();
  printCurrentAction();
  
  //LCDSerial.print("?x00?y3");
  //LCDSerial.print(sizeof(ThermoConfig));
  //LCDSerial.print(" bytes");
}

void saveSettings(){
  int addr = MEM_START + 1;
  EEPROM_writeAnything(MEM_START + 1, ThermoConfig);
}

void restoreSettings(){
  if(EEPROM.read(MEM_START) != MEM_PROGID){
    clearEeprom();
    saveSettings();
    return;
  }
  EEPROM_readAnything(MEM_START + 1, ThermoConfig);
}

void clearEeprom(){
  EEPROM.write(MEM_START, MEM_PROGID);
  for (int i=(MEM_START + 1); i<MEM_LENGTH; i++){
    // Using 255 for blank locations
    EEPROM.write(i, 255);
  }
}

void HVAC_Controller(){
  if(currentAction == ACTION_WAIT){
    if(waitingEnd > millis()){
      // Still waiting
      return;
    }else{
      // Finished waiting, set state to off
      setAction(ACTION_OFF);
    }
  }
  if(ThermoConfig.currentMode == MODE_OFF){
    // The thermostat is in OFF mode
    if(currentAction != ACTION_OFF){
      HVAC_DisableAll();
    }
    return;
  }
  
  // Abstracting all the logic so I can actually read the code :)
  boolean isHeating = (currentAction == ACTION_HEAT);
  boolean isCooling = (currentAction == ACTION_AC);
  boolean isOff = (currentAction == ACTION_OFF);
  boolean isFan = (currentAction == ACTION_FAN);
  
  boolean inHeatingMode = (ThermoConfig.currentMode == MODE_HEAT_ONLY || lastHeat >= lastAC);
  boolean inCoolingMode = (ThermoConfig.currentMode == MODE_AC_ONLY || lastHeat < lastAC);
  
  boolean sameModeTooCold   = (ThermoConfig.avgTemp <= (ThermoConfig.targetTemp - ThermoConfig.tempLowerBuffer));
  boolean sameModeTooHot    = (ThermoConfig.avgTemp >= (ThermoConfig.targetTemp + ThermoConfig.tempUpperBuffer));
  boolean switchModeTooCold = (ThermoConfig.avgTemp <= (ThermoConfig.targetTemp - ThermoConfig.tempModeChangeLowerBuffer));
  boolean switchModeTooHot  = (ThermoConfig.avgTemp >= (ThermoConfig.targetTemp + ThermoConfig.tempModeChangeUpperBuffer));
  
  boolean reachedOverHeat = (ThermoConfig.avgTemp >= (ThermoConfig.targetTemp + ThermoConfig.overHeatAmount));
  boolean reachedOverCool = (ThermoConfig.avgTemp <= (ThermoConfig.targetTemp - ThermoConfig.overCoolAmount));

  /**
   * Menu choices may have made the logic inconsistent
   */
  if( (isHeating || isCooling || isFan) && (ThermoConfig.currentMode == MODE_OFF) ){
    HVAC_DisableAll();
    return;
  }
  if( (isHeating && ThermoConfig.currentMode == MODE_AC_ONLY) || (isCooling && ThermoConfig.currentMode == MODE_HEAT_ONLY) ){
    HVAC_DisableAll();
    return;
  }
  // The logic may have inHeatingMode == true while in AC ONLY mode;
  // this happens the cycle after a user chooses HEAT ONLY while in heating mode
  if(inHeatingMode && ThermoConfig.currentMode == MODE_AC_ONLY){
    inHeatingMode = false;
    inCoolingMode = true;
  }
  if(inCoolingMode && ThermoConfig.currentMode == MODE_HEAT_ONLY){
    inHeatingMode = true;
    inCoolingMode = false;
  }

  

  /**
   * HEATING MODE
   */
  if(inHeatingMode){
    if(isHeating){
      if(reachedOverHeat){
        // We're up to the overtemp, turn off the heat
        HVAC_DisableAll();
        return;
      }else{
        // Still heating
        return;
      }
    }
    if(isOff){
      if(sameModeTooCold){
        // The temp dropped below the lower limit, turn on the heat
        HVAC_SafeEnable(RELAY_HEAT);
        return;
      }
      if(switchModeTooHot){
        // It's so hot that we need to switch into AC mode
        if(ThermoConfig.currentMode == MODE_HEAT_ONLY){
          // We can't turn on the AC because we're in HEAT ONLY mode
          return;
        }
        if(DEBUG){Serial.println("Switching from Heating mode to Cooling mode");}
        HVAC_SafeEnable(RELAY_AC);
        return;
      }
    }
  }else{
  /**
   * COOLING MODE
   */
    if(isCooling){
      if(reachedOverCool){
        // We're down to the overcool temp, turn off the AC
        HVAC_DisableAll();
        return;
      }else{
        // We're still cooling
        return;
      }
    }
    if(isOff){
      if(sameModeTooHot){
        // It's too hot, turn on the AC
        HVAC_SafeEnable(RELAY_AC);
        return;
      }
      if(switchModeTooCold){
        // It's so cold that we need to switch into heating mode
        if(ThermoConfig.currentMode == MODE_AC_ONLY){
          // We can't turn on the Heat because we're in AC ONLY mode
          return;
        }
        if(DEBUG){Serial.println("Switching from Cooling mode to Heating mode");}
        HVAC_SafeEnable(RELAY_HEAT);
        return;
      }
    }
  }
}

void getTemps(){
  double tempTemp = 0.0;
  int tempCount = 0;
  for(int i=0; i<NUM_ZONES; i++){
    zoneTemps[i] = Thermistor(analogRead(zonePins[i])) + zoneTempOffsets[i];
    //zoneTemps[i] = random(68,78);
    if(zonesIncludedInAvg[i]){
      tempTemp += zoneTemps[i];
      tempCount++;
    }
    delay(sensorDelay);
  }
  if(tempCount > 0){
    addAvgTemp(tempTemp / tempCount);
    ThermoConfig.avgTemp = getAvgTemp();
  }
}
void addAvgTemp(double temp){
  static int writePointer = -1;
  if(writePointer == -1){
    // This is the first run-through, initialize the pointer and array
    writePointer = 0;
    for(int i=0; i<numTempSamples; i++){
      lastTemps[i] = temp;
    }
  }
  if(++writePointer >= numTempSamples) writePointer = 0;
  lastTemps[writePointer] = temp;
}
double getAvgTemp(){
  double tempTemp = 0.0;
  //if(DEBUG){Serial.print("Current buffer temps: ");}
  for(int i=0; i<numTempSamples; i++){
    tempTemp += lastTemps[i];
    //if(DEBUG){printDouble(lastTemps[i],1);Serial.print(" ");}
  }
  //if(DEBUG){Serial.println();}
  return tempTemp / double(numTempSamples);
}
void sendSerial(){
  if(Serial.available() == 0){
    return;
  }
  int inByte = Serial.read();
  Serial.print("Zone1:");
  printDouble(zoneTemps[0],3);
  Serial.print(" Zone2:");
  printDouble(zoneTemps[1],3);
  Serial.print(" Zone3:");
  printDouble(zoneTemps[2],3);
  Serial.print(" Zone4:");
  printDouble(zoneTemps[3],3);
  Serial.println("");
}
double Thermistor(int RawADC) {
  long Resistance;
  double Temp;
  Resistance=((10240000/RawADC) - 10000);
  Temp = log(Resistance);
  Temp = 1 / (0.001129148 + (0.000234125 * Temp) + (0.0000000876741 * Temp * Temp * Temp));
  Temp = Temp - 273.15;
  Temp = (Temp * 9.0)/ 5.0 + 32.0;
  return Temp;
}

void printDouble(double val, byte precision) {
  // prints val with number of decimal places determine by precision
  // precision is a number from 0 to 6 indicating the desired decimal places
  // example: printDouble(3.1415, 2); // prints 3.14 (two decimal places)
  Serial.print (int(val));  //prints the int part
  if( precision > 0) {
    Serial.print("."); // print the decimal point
    unsigned long frac, mult = 1;
    byte padding = precision -1;
    while(precision--) mult *=10;
    if(val >= 0) frac = (val - int(val)) * mult; else frac = (int(val) - val) * mult;
    unsigned long frac1 = frac;
    while(frac1 /= 10) padding--;
    while(padding--) Serial.print("0");
    Serial.print(frac,DEC) ;
  }
}
void onSelectPress(){
  // prevent entering menu on reset
  if(millis() < 2000) return;
  // debounce button press
  if(millis() < (lastButtonPress + 250)) return;
  lastButtonPress = millis();
  if(inMenu){
    switch(menuState){
      case MENU_OFF:
        changeMenu(MENU_MODE);
        break;
      case MENU_MODE:
        changeMenu(MENU_CONFIG);
        break;
      case MENU_CONFIG:
        repaintScreen();
        changeMenu(MENU_OFF);
        break;
    }
  }else{
    inMenu = true;
    changeMenu(MENU_MODE);
  }
}

void checkUpDownButtons(){
  int dir = 0;
  if(digitalRead(selectUpPin) == LOW)
    dir = 1;
  if(digitalRead(selectDownPin) == LOW)
    dir = -1;
  if(dir == 0)
    return;
  
  lastButtonPress = millis();
  if(!inMenu){
    incrementTargetTemp(dir);
    delay(250);
  }else switch(menuState){
    case MENU_MODE:
      incrementMode(dir);
      delay(250);
      break;
    case MENU_CONFIG:
      incrementConfig(dir);
      delay(250);
      break;
    default:
      break;
    }
}

void incrementTargetTemp(int amount){
  ThermoConfig.targetTemp += amount;
  LCDSerial.print("?x05?y1");
  LCDPrintDouble(ThermoConfig.targetTemp,0);
  LCDSerial.print("?0 ");
}

void printAvgTemp(){
  LCDSerial.print("?x05?y0");
  LCDPrintDouble(ThermoConfig.avgTemp,0);
  LCDSerial.print("?0 ");
}

void incrementConfig(int dir){
  if(dir > 0){
    if(++configMenuPage > 2) configMenuPage = 0;
  }else{
    if(--configMenuPage < 0) configMenuPage = 2;
  }
  switch(configMenuPage){
    case 0:
      repaintScreen();
      changeMenu(MENU_CONFIG);
      break;
    case 1:
      //                      01234567890123456789
      LCDSerial.print("?x00?y0UpperBuffer         ");
      LCDSerial.print("?x00?y1LowerBuffer         ");
      LCDSerial.print("?x00?y2ChangeUpperBuffr    ");
      LCDSerial.print("?x00?y3ChangeLowerBuffr    ");
      LCDSerial.print("?x17?y0"); LCDPrintDouble(ThermoConfig.tempUpperBuffer,1);
      LCDSerial.print("?x17?y1"); LCDPrintDouble(ThermoConfig.tempLowerBuffer,1);
      LCDSerial.print("?x17?y2"); LCDPrintDouble(ThermoConfig.tempModeChangeUpperBuffer,1);
      LCDSerial.print("?x17?y3"); LCDPrintDouble(ThermoConfig.tempModeChangeLowerBuffer,1);
      break;
    case 2:
      LCDSerial.print("?x00?y0OverHeatAmount      ");
      LCDSerial.print("?x00?y1OverCoolAmount      ");
      LCDSerial.print("?x00?y2                    ");
      LCDSerial.print("?x00?y3                    ");
      LCDSerial.print("?x17?y0"); LCDPrintDouble(ThermoConfig.overHeatAmount,1);
      LCDSerial.print("?x17?y1"); LCDPrintDouble(ThermoConfig.overCoolAmount,1);
      break;
  }
}

void incrementMode(int dir){
  if(dir > 0 && ThermoConfig.currentMode >= 0 && ThermoConfig.currentMode < 3){
    // Going up
    setMode(ThermoConfig.currentMode + 1);
    return;
  }else if(dir > 0){
    setMode(0);
  }else if(ThermoConfig.currentMode > 0){
    // Going down
    setMode(ThermoConfig.currentMode - 1);
  }else{
    setMode(3);
  }    
}

void setMode(int newMode){
  LCDSerial.print("?x10?y0");
  switch(newMode){
    case MODE_AUTO:
      LCDSerial.print(" Full Auto");
      break;
    case MODE_HEAT_ONLY:
      LCDSerial.print(" Auto Heat");
      break;
    case MODE_AC_ONLY:
      LCDSerial.print("  Auto A/C");
      break;
    case MODE_OFF:
      LCDSerial.print("System Off");
      break;
  }
  ThermoConfig.currentMode = newMode;
}

void changeMenu(int newState){
  switch(newState){
      case MENU_MODE:
        LCDSerial.print("?x00?y3");
        LCDSerial.print("  * Select Mode *   ");
        LCDSerial.print("?x09?y0>");
        break;
      case MENU_CONFIG:
        LCDSerial.print("?x00?y3");
        LCDSerial.print("  * View Config *   ");
        LCDSerial.print("?x09?y0 ");
        break;
      default:
        LCDSerial.print("?x00?y3");
        LCDSerial.print("  * Save & Exit *   ");
        LCDSerial.print("?x09?y0 ");
        break;
  }
  menuState = newState;
}

void clearMenu(){
  menuState = MENU_OFF;
  LCDSerial.print("?x00?y3                    ");
  LCDSerial.print("?x09?y0 ");
}

void printCurrentAction(){
  LCDSerial.print("?x09?y1");
  switch(currentAction){
    default:
    case ACTION_OFF:
      LCDSerial.print("           ");
      break;
    case ACTION_HEAT:
      LCDSerial.print("    Heating");
      break;
    case ACTION_AC:
      LCDSerial.print("    Cooling");
      break;
    case ACTION_FAN:
      LCDSerial.print("        Fan");
      break;
    case ACTION_WAIT:
      LCDSerial.print("* Waiting *");
      break;
  }
}

const int backlightThreshold = 20;
void autoSetBacklight(){
  static int lastBacklightValue = 0;
  int photoValue = analogRead(PHOTORES_PIN);
  delay(20);
  photoValue += analogRead(PHOTORES_PIN);
  delay(20);
  photoValue += analogRead(PHOTORES_PIN);
  delay(20);
  photoValue += analogRead(PHOTORES_PIN);
  photoValue = photoValue / 4;
  int backlightValue = map(photoValue, 0, 1023, 0, 255);
  backlightValue = constrain(photoValue, 1, 200);
  if(backlightValue <= 3){
    backlightValue = 1;
  }else if(backlightValue / backlightThreshold == lastBacklightValue / backlightThreshold){
    return;
  }
  LCDSerial.print("?B");
  LCDPrintHEX(backlightValue);
  lastBacklightValue = backlightValue;
  delay(100);
}
int LCDPrintHEX(int in){
  if(in < 0x10){
    LCDSerial.print("0");
  }
  LCDSerial.print(in, HEX);
}
void clearLCD(){
  LCDSerial.print("?f");
}
void LCDPrintDouble(double val, byte precision) {
  // prints val with number of decimal places determine by precision
  // precision is a number from 0 to 6 indicating the desired decimal places
  // example: printDouble(3.1415, 2); // prints 3.14 (two decimal places)
  LCDSerial.print (int(val));  //prints the int part
  if( precision > 0) {
    LCDSerial.print("."); // print the decimal point
    unsigned long frac, mult = 1;
    byte padding = precision -1;
    while(precision--) mult *=10;
    if(val >= 0) frac = (val - int(val)) * mult; else frac = (int(val) - val) * mult;
    unsigned long frac1 = frac;
    while(frac1 /= 10) padding--;
    while(padding--) LCDSerial.print("0");
    LCDSerial.print(frac,DEC) ;
  }
}

void setAction(int type){
  currentAction = type;
  printCurrentAction();
}
void setWaitTime(unsigned long waitTime){
  waitingEnd = millis() + waitTime;
  setAction(ACTION_WAIT);
}
void HVAC_SafeEnable(int type){
  switch(type){
    /*** FAN ***/
    case RELAY_FAN:
      // TRANSITION: HEAT/AC to FAN
      if(currentACState == 1 || currentHeatState == 1){
        HVAC_Disable(RELAY_AC);
        setWaitTime(TRANS_DELAY_FAN);
        break;
      }
      setAction(ACTION_FAN);
      HVAC_Enable(RELAY_FAN);
      break;
    /*** HEAT ***/
    case RELAY_HEAT:
      if(currentFanState == 1){
        HVAC_Disable(RELAY_FAN);
        setWaitTime(TRANS_DELAY_FAN);
        break;
      }
      if(currentACState == 1){
        // TRANSITION: AC to HEAT
        HVAC_Disable(RELAY_AC);
        setWaitTime(TRANS_DELAY_AC_HEAT);
        break;
      }
      setAction(ACTION_HEAT);
      HVAC_Enable(RELAY_HEAT);
      break;
    /*** AC ***/
    case RELAY_AC:
      if(currentFanState == 1){
        HVAC_Disable(RELAY_FAN);
        setWaitTime(TRANS_DELAY_FAN);
        break;
      }
      if(currentHeatState == 1){
        // TRANSITION: HEAT to AC
        HVAC_Disable(RELAY_HEAT);
        setWaitTime(TRANS_DELAY_HEAT_AC);
        break;
      }
      setAction(ACTION_AC);
      HVAC_Enable(RELAY_AC);
      break;
  }
}

void HVAC_Enable(int type){
  if(type == RELAY_HEAT) lastHeat = millis();
  if(type == RELAY_AC) lastAC = millis();
  digitalWrite(type, LOW);
  setRelayState(type, 1);
}

void HVAC_Disable(int type){
  digitalWrite(type, HIGH);
  setRelayState(type, 0);
}

void HVAC_DisableAll(){
  HVAC_Disable(RELAY_FAN);
  HVAC_Disable(RELAY_HEAT);
  HVAC_Disable(RELAY_AC);
  setAction(ACTION_OFF);
}

void setRelayState(int type, int state){
  switch(type){
    case RELAY_FAN:
      currentFanState = state;
      break;
    case RELAY_HEAT:
      currentHeatState = state;
      break;
    case RELAY_AC:
      currentACState = state;
      break;
  }
}

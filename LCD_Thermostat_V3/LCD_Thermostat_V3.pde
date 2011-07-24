#include "Thermostat.h"

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

//Schematic:
// [Ground] ---- [10k-Resister] -------|------- [Thermistor/Photoresistor] ---- [+5v]
//                                     |
//                                Analog Pin

const boolean DEBUG = false;

// LCD Serial Connection
SoftwareSerial LCDSerial =  SoftwareSerial(LCD_RX_PIN, LCD_TX_PIN);

// Number of Zone sensors (10k thermistors)
const int NUM_ZONES = 4;
// The actual zone temps
double zoneTemps[NUM_ZONES];
// The last x temps, used for filtering noise
const int NUM_TEMP_SAMPLES = 20;
double lastTemps[NUM_TEMP_SAMPLES];
// Zone adjustment offsets (added to the raw temperature)
//                           Zone:   1    2    3     4
double zoneTempOffsets[NUM_ZONES] = {0.0, 0.0, 0.0, 0.0};
// Which zones to include in the average temp, which drives the thermostat
const boolean zonesIncludedInAvg[NUM_ZONES] = {true, true, true, false};
// Milliseconds to wait between reading temp sensors
int sensorDelay = 0;

// Default configuration object
struct config_t {
  // Target to keep the temp around
  double targetTemp;
  
  // Rolling avg composite temperature
  double avgTemp;
  
  // Buffer before re-enabling Heat or AC
  // Ex: Upper Buffer: 0.75, Temp Set: 72, Heat will come on at 71.25
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
  1.25,  // tempUpperBuffer
  1.25,  // tempLowerBuffer
  4.0,  // tempModeChangeUpperBuffer
  4.0,  // tempModeChangeLowerBuffer
  1.0,  // overHeatAmout
  1.0,  // overCoolAmount
  0     // currrentMode
};

// Thermistor Pins
const int zonePins[NUM_ZONES] = {A1, A2, A3, A4};

// Thermostat object to control HVAC relays
Thermostat therm;

// Button/Menu States
volatile boolean inMenu = false;
volatile int menuState = 0;
volatile unsigned long lastButtonPress = 0;
const unsigned int MENU_TIMEOUT = 20000;
const unsigned int MENU_SAVE_TIMEOUT = 1000;

int configMenuPage = 0;

boolean buttonUpPressed = false;
boolean buttonDownPressed = false;

// Timing variables
const unsigned long FAST_TIMER_DELAY = 1000;
const unsigned long SLOW_TIMER_DELAY = 5000;
unsigned long fastTimer = 0;
unsigned long slowTimer = 0;

void setup() {
  //Serial.begin(9600);
  therm.serialDebug(false);
  // Restore settings from EEPROM, if available
  restoreSettings();
  
  // Buttons
  pinMode(SELECT_BUTTON_PIN, INPUT);
  digitalWrite(SELECT_BUTTON_PIN, HIGH);
  attachInterrupt(0, onSelectPress, RISING);
  pinMode(UP_BUTTON_PIN, INPUT);
  digitalWrite(UP_BUTTON_PIN, HIGH);
  pinMode(DOWN_BUTTON_PIN, INPUT);
  digitalWrite(DOWN_BUTTON_PIN, HIGH);
  
  // LCD
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
    //sendSerial();

    // Fast events (every 1 sec or so)
    if((millis() - fastTimer) > FAST_TIMER_DELAY){
      getTemps();
      printAvgTemp();
      autoSetBacklight();
      HVAC_Controller();
      
      
      fastTimer = millis();
    }

    // Slow events (every 5 sec or so)
    if((millis() - slowTimer) > SLOW_TIMER_DELAY){
      printZoneTemps();
      slowTimer = millis();
    }
    
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
  LCDSerial.print("?x00?y0                    ");
  LCDSerial.print("?x00?y1 Arduino Thermostat ");
  LCDSerial.print("?x00?y2 by Steve Kamerman  ");
  LCDSerial.print("?x00?y3                    ");
  delay(10000);
  
  getTemps();
  repaintScreen();  
}

void repaintScreen(){
  //clearLCD();
  LCDSerial.print("?x00?y0Temp ---            ");
  LCDSerial.print("?x00?y1Set  ---            ");
//  LCDSerial.print("?x00?y2                    ");
//  LCDSerial.print("?x00?y3                    ");
  
  setMode(ThermoConfig.currentMode);
  incrementTargetTemp(0);
  printAvgTemp();
  printZoneTemps();
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
  if(therm.isWaiting()){
    // Still waiting
    return;
  }else{
    // Update display if necessary
    printCurrentAction();
  }
  if(ThermoConfig.currentMode == MODE_OFF){
    // The thermostat is in OFF mode
    if(!therm.isAction(ACTION_OFF)){
      therm.turnAllOff();
      printCurrentAction();
    }
    return;
  }
  
  // Abstracting the logic so I can actually read the code :)
  boolean inHeatingMode = (ThermoConfig.currentMode == MODE_HEAT_ONLY || therm.getLastOnTime(THERMO_HEAT) >= therm.getLastOnTime(THERMO_AC));
  boolean inCoolingMode = (ThermoConfig.currentMode == MODE_AC_ONLY || therm.getLastOnTime(THERMO_HEAT) < therm.getLastOnTime(THERMO_AC));
  
  boolean sameModeTooCold   = (ThermoConfig.avgTemp <= (ThermoConfig.targetTemp - ThermoConfig.tempLowerBuffer));
  boolean sameModeTooHot    = (ThermoConfig.avgTemp >= (ThermoConfig.targetTemp + ThermoConfig.tempUpperBuffer));
  boolean switchModeTooCold = (ThermoConfig.avgTemp <= (ThermoConfig.targetTemp - ThermoConfig.tempModeChangeLowerBuffer));
  boolean switchModeTooHot  = (ThermoConfig.avgTemp >= (ThermoConfig.targetTemp + ThermoConfig.tempModeChangeUpperBuffer));
  
  boolean reachedOverHeat = (ThermoConfig.avgTemp >= (ThermoConfig.targetTemp + ThermoConfig.overHeatAmount));
  boolean reachedOverCool = (ThermoConfig.avgTemp <= (ThermoConfig.targetTemp - ThermoConfig.overCoolAmount));

  /**
   * Menu choices may have made the logic inconsistent
   */
  if( (therm.isAction(ACTION_HEAT) || therm.isAction(ACTION_AC) || therm.isAction(ACTION_FAN)) && (ThermoConfig.currentMode == MODE_OFF) ){
    therm.turnAllOff();
    printCurrentAction();
    return;
  }
  if( (therm.isAction(ACTION_HEAT) && ThermoConfig.currentMode == MODE_AC_ONLY) || (therm.isAction(ACTION_AC) && ThermoConfig.currentMode == MODE_HEAT_ONLY) ){
    therm.turnAllOff();
    printCurrentAction();
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
    if(therm.isAction(ACTION_HEAT)){
      if(reachedOverHeat){
        // We're up to the overtemp, turn off the heat
        therm.turnAllOff();
        printCurrentAction();
        return;
      }else{
        // Still heating
        return;
      }
    }
    if(therm.isAction(ACTION_OFF)){
      if(sameModeTooCold){
        // The temp dropped below the lower limit, turn on the heat
        therm.turnOn(THERMO_HEAT);
        printCurrentAction();
        return;
      }
      if(switchModeTooHot){
        // It's so hot that we need to switch into AC mode
        if(ThermoConfig.currentMode == MODE_HEAT_ONLY){
          // We can't turn on the AC because we're in HEAT ONLY mode
          return;
        }
        if(DEBUG){Serial.println("Switching from Heating mode to Cooling mode");}
        therm.turnOn(THERMO_AC);
        printCurrentAction();
        return;
      }
    }
  }else{
  /**
   * COOLING MODE
   */
    if(therm.isAction(ACTION_AC)){
      if(reachedOverCool){
        // We're down to the overcool temp, turn off the AC
        therm.turnAllOff();
        printCurrentAction();
        return;
      }else{
        // We're still cooling
        return;
      }
    }
    if(therm.isAction(ACTION_OFF)){
      if(sameModeTooHot){
        // It's too hot, turn on the AC
        therm.turnOn(THERMO_AC);
        printCurrentAction();
        return;
      }
      if(switchModeTooCold){
        // It's so cold that we need to switch into heating mode
        if(ThermoConfig.currentMode == MODE_AC_ONLY){
          // We can't turn on the Heat because we're in AC ONLY mode
          return;
        }
        if(DEBUG){Serial.println("Switching from Cooling mode to Heating mode");}
        therm.turnOn(THERMO_HEAT);
        printCurrentAction();
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
    for(int i=0; i<NUM_TEMP_SAMPLES; i++){
      lastTemps[i] = temp;
    }
  }
  if(++writePointer >= NUM_TEMP_SAMPLES) writePointer = 0;
  lastTemps[writePointer] = temp;
}
double getAvgTemp(){
  double tempTemp = 0.0;
  //if(DEBUG){Serial.print("Current buffer temps: ");}
  for(int i=0; i<NUM_TEMP_SAMPLES; i++){
    tempTemp += lastTemps[i];
    //if(DEBUG){printDouble(lastTemps[i],1);Serial.print(" ");}
  }
  //if(DEBUG){Serial.println();}
  return tempTemp / double(NUM_TEMP_SAMPLES);
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
  if(digitalRead(UP_BUTTON_PIN) == LOW)
    dir = 1;
  if(digitalRead(DOWN_BUTTON_PIN) == LOW)
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

void printZoneTemps(){
  if(inMenu) return;
  
  LCDSerial.print("?x00?y2-----Zone Temps-----");
  LCDSerial.print("?x00?y3Em ");
  LCDSerial.print(int(zoneTemps[0]));
  LCDSerial.print(" Mst ");
  LCDSerial.print(int(zoneTemps[1]));
  LCDSerial.print(" Lvng ");
  LCDSerial.print(int(zoneTemps[2]));
  /*
  // Zone 1: Daughter's Room
  LCDSerial.print("?x05?y2");
  LCDPrintDouble(zoneTemps[0],0);
  LCDSerial.print("?0 ");
  // Zone 2: Master Bedroom
  LCDSerial.print("?x16?y2");
  LCDPrintDouble(zoneTemps[1],0);
  LCDSerial.print("?0 ");
  // Zone 3: Living Room
  LCDSerial.print("?x12?y3");
  LCDPrintDouble(zoneTemps[2],0);
  LCDSerial.print("?0 ");
  */
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
        LCDSerial.print("?x00?y2                    ");
        LCDSerial.print("?x00?y3");
        LCDSerial.print("  * Select Mode *   ");
        LCDSerial.print("?x09?y0>");
        break;
      case MENU_CONFIG:
        LCDSerial.print("?x00?y2                    ");
        LCDSerial.print("?x00?y3");
        LCDSerial.print("  * View Config *   ");
        LCDSerial.print("?x09?y0 ");
        break;
      default:
        LCDSerial.print("?x00?y2                    ");
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
  printZoneTemps();
}

void printCurrentAction(){
  static int lastAction = -1;
  LCDSerial.print("?x09?y1");
  switch(therm.getCurrentAction()){
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
      LCDSerial.print("    Waiting");
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
backlightValue = 100;
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

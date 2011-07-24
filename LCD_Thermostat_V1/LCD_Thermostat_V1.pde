// LCD117 Command Reference: http://cdn.shopify.com/s/files/1/0038/9582/files/LCD117_Board_Command_Summary.pdf?1260768875

#include <math.h>
#include <SoftwareSerial.h>
//Schematic:
// [Ground] ---- [10k-Resister] -------|------- [Thermistor/Photoresistor] ---- [+5v]
//                                     |
//                                Analog Pin

const int LCD_ROWS = 4;
const int LCD_COLUMNS = 20;

// Number of Zone sensors (10k thermistors)
const int numZones = 4;
double zoneTemps[numZones];
// Zone adjustment offsets (added to the raw temperature)
//                           Zone:   1    2    3     4
double zoneTempOffsets[numZones] = {0.0, 0.0, 0.0, -12.0};
int sensorDelay = 10;

/*** DIGITAL PINS ***/
const int txPin = 10;        // LCD Serial TX
const int rxPin = 11;        // LCD Serial RX (unused)
/*** ANALOG PINS ***/
const int photoPin = A0;     // Photoresistor Pin
// Thermistor Pins
const int zonePins[numZones] = {A1, A2, A3, A4};

// LCD Serial Connection
SoftwareSerial LCDSerial =  SoftwareSerial(rxPin, txPin);

// Declare functions
void setup();
void loop();
void getTemps();
void sendSerial();
double Thermistor(int RawADC);
void printDouble(double val, byte precision);
void updateLCDTemps();
void autoSetBacklight();
int LCDPrintHEX(int in);
void clearLCD();
void LCDPrintDouble(double val, byte precision);

void setup() {
  Serial.begin(115200);
  pinMode(txPin, OUTPUT);
  LCDSerial.begin(9600);
  LCDSerial.print("?G" + LCD_ROWS + LCD_COLUMNS);
  delay(100);
  LCDSerial.print("?c0");
  // Define degree custom char for print("?0");
  LCDSerial.print("?D00609090600000000");
  clearLCD();
  autoSetBacklight();
  delay(100);
}
void loop() {
  getTemps();
  updateLCDTemps();
  autoSetBacklight();
  sendSerial();
  delay(500);
}
void getTemps(){
  for(int i=0; i<numZones; i++){
    zoneTemps[i] = Thermistor(analogRead(zonePins[i])) + zoneTempOffsets[i];
    delay(sensorDelay);
  }
}
void sendSerial(){
    if (Serial.available() == 0){
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
 long Resistance;  double Temp;
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

// LCD Functions
void updateLCDTemps(){
  LCDSerial.print("?x00?y0");
  //               01234567890123456789
  LCDSerial.print("xxxx's Room:  ");
  LCDPrintDouble(zoneTemps[0],0);
  LCDSerial.print("?0 ");
  LCDSerial.print("?x00?y1");
  LCDSerial.print("Our Room:     ");
  LCDPrintDouble(zoneTemps[1],0);
  LCDSerial.print("?0 ");
  LCDSerial.print("?x00?y2");
  LCDSerial.print("Living Room:  ");
  LCDPrintDouble(zoneTemps[2],0);
  LCDSerial.print("?0 ");
  LCDSerial.print("?x00?y3");
  LCDSerial.print("Outside:      ");
  LCDPrintDouble(zoneTemps[3],0);
  LCDSerial.print("?0 ");
}
const int backlightThreshold = 20;
void autoSetBacklight(){
  static int lastBacklightValue = 0;
  int photoValue = analogRead(photoPin);
  delay(20);
  photoValue += analogRead(photoPin);
  delay(20);
  photoValue += analogRead(photoPin);
  delay(20);
  photoValue += analogRead(photoPin);
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

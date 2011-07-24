#include <math.h>
//Schematic:
// [Ground] ---- [10k-Resister] -------|------- [Thermistor] ---- [+5v]
//                                     |
//                                Analog Pin

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

void setup() {
 Serial.begin(115200);
}

#define ZoneOne 1   // Analog Pin 1
#define ZoneTwo 2   // Analog Pin 2
#define ZoneThree 3   // Analog Pin 3
#define ZoneFour 4   // Analog Pin 4


double temp;

void loop() {
 Serial.print("Zone 1: ");
 printDouble(Thermistor(analogRead(ZoneOne)),3);
 Serial.println("");

 Serial.print("Zone 2: ");
 printDouble(Thermistor(analogRead(ZoneTwo)),3);
 Serial.println("");

 Serial.print("Zone 3: ");
 printDouble(Thermistor(analogRead(ZoneThree)),3);
 Serial.println("");
 /*
 Serial.print("Zone 4: ");
 printDouble(Thermistor(analogRead(ZoneFour)),3);
 Serial.println("");
 */
 Serial.println("");
 delay(5000);
}

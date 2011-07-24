/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the Arduino Powered Thermostat
 *
 * The Initial Developer of the Original Code is Steve Kamerman.
 * Portions created by the Initial Developer are Copyright (C) 2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * ***** END LICENSE BLOCK ***** */
 
#ifndef Thermostat_h
#define Thermostat_h

#include <Wprogram.h>

// Relay Pins
#define RELAY_FAN_PIN  6
#define RELAY_HEAT_PIN 7
#define RELAY_AC_PIN   8

#define THERMO_HEAT 0
#define THERMO_AC   1
#define THERMO_FAN  2

#define ACTION_OFF  0
#define ACTION_HEAT 1
#define ACTION_AC   2
#define ACTION_FAN  3
#define ACTION_WAIT 4

// Menu constants
#define MENU_OFF    0
#define MENU_MODE   1
#define MENU_CONFIG 2

// Mode constants
#define MODE_AUTO      0
#define MODE_HEAT_ONLY 1
#define MODE_AC_ONLY   2
#define MODE_OFF       3

// Button pins
#define SELECT_BUTTON_PIN  2
#define UP_BUTTON_PIN      4
#define DOWN_BUTTON_PIN    3

// LCD settings
#define LCD_ROWS      4
#define LCD_COLUMNS  20
#define LCD_TX_PIN   10
#define LCD_RX_PIN   11
#define PHOTORES_PIN A0

// Starting EEPROM address
#define MEM_START  0
// Memory length (the 328P has 1024b)
#define MEM_LENGTH 64
// Identifier - if missing from MEM_START location, memory is wiped and defaults are used
#define MEM_PROGID 116


class Thermostat {
  
  public:
    Thermostat();
    void turnAllOff();
    boolean turnOn(int type);
    void turnOff(int type);
    boolean isOn(int type);
    boolean isWaiting();
    unsigned long waitingSecLeft();
    void serialDebug(boolean enable);
    const char* typeToName(int type);
    unsigned long getLastOnTime(int type);
    int getCurrentAction();
    boolean isAction(int action);

    unsigned long _waitUntil;
  private:
    unsigned long _acOffDelay;
    unsigned long _heatOffDelay;
    int _relayPins[3];
    boolean _typeOnOff[3];
    unsigned long _lastOnTime[3];
    boolean _debug;

    void _setRelay(int type, boolean on);
    void _setWait(unsigned long time);
};

#endif

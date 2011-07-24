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
 
const int RELAY_FAN  = 6;
const int RELAY_HEAT = 7;
const int RELAY_AC   = 8;

int STATE_FAN  = 0;
int STATE_HEAT = 0;
int STATE_AC   = 0;

void setup() {
  // put your setup code here, to run once:
  Serial.begin(115200);
  
  pinMode(RELAY_FAN, OUTPUT);
  pinMode(RELAY_HEAT, OUTPUT);
  pinMode(RELAY_AC, OUTPUT);
  HVAC_DisableAll();
  //delay(5000);
  //HVAC_SafeEnable(RELAY_HEAT);
}

void loop() {

  Serial.println("---- Testing FAN ----");
  HVAC_SafeEnable(RELAY_FAN);
  delay(10000);
  Serial.println("---- Testing HEAT ----");
  HVAC_SafeEnable(RELAY_HEAT);
  delay(10000);
  Serial.println("---- Testing AC ----");
  HVAC_SafeEnable(RELAY_AC);
  delay(10000);

}

const int TRANS_DELAY_FAN = 250;
const int TRANS_DELAY_AC_HEAT = 750;
const int TRANS_DELAY_HEAT_AC = 500;

void HVAC_SafeEnable(int type){
  switch(type){
    /*** FAN ***/
    case RELAY_FAN:
      // TRANSITION: HEAT/AC to FAN
      if(STATE_AC == 1){
        HVAC_Disable(RELAY_AC);
        delay(TRANS_DELAY_FAN);
      }
      if(STATE_HEAT == 1){
        HVAC_Disable(RELAY_HEAT);
        delay(TRANS_DELAY_FAN);
      }
      HVAC_Enable(RELAY_FAN);
      break;
    /*** HEAT ***/
    case RELAY_HEAT:
      if(STATE_FAN == 1){
        HVAC_Disable(RELAY_FAN);
        delay(TRANS_DELAY_FAN);
      }
      if(STATE_AC == 1){
        // TRANSITION: AC to HEAT
        HVAC_Disable(RELAY_AC);
        delay(TRANS_DELAY_AC_HEAT);
      }
      HVAC_Enable(RELAY_HEAT);
      break;
    /*** AC ***/
    case RELAY_AC:
      if(STATE_FAN == 1){
        HVAC_Disable(RELAY_FAN);
        delay(TRANS_DELAY_FAN);
      }
      if(STATE_HEAT == 1){
        // TRANSITION: HEAT to AC
        HVAC_Disable(RELAY_HEAT);
        delay(TRANS_DELAY_HEAT_AC);
      }
      HVAC_Enable(RELAY_AC);
      break;
  }
}

void HVAC_Enable(int type){
  Serial.print("Enabling ");
  Serial.println(type);
  
  digitalWrite(type, LOW);
  setState(type, 1);
}

void HVAC_Disable(int type){
  Serial.print("Disabling ");
  Serial.println(type);
  
  digitalWrite(type, HIGH);
  setState(type, 0);
}

void HVAC_DisableAll(){
  HVAC_Disable(RELAY_FAN);
  HVAC_Disable(RELAY_HEAT);
  HVAC_Disable(RELAY_AC);
}

void setState(int type, int state){
  switch(type){
    case RELAY_FAN:
      STATE_FAN = state;
      break;
    case RELAY_HEAT:
      STATE_HEAT = state;
      break;
    case RELAY_AC:
      STATE_AC = state;
      break;
  }
}

#include "Thermostat.h"

unsigned long _acOffDelay;
unsigned long _heatOffDelay;
int _relayPins[3] = {0,0,0};
boolean _typeOnOff[3] = {false, false, false};
unsigned long lastOnTime[3] = {1, 0, 0};
// Initial wait time of 60 sec after reset
unsigned long _waitUntil = 60000;
boolean _debug = false;

Thermostat::Thermostat(){
  _acOffDelay = 300000;
  _heatOffDelay = 120000;
  _relayPins[0] = RELAY_HEAT_PIN;
  _relayPins[1] = RELAY_AC_PIN;
  _relayPins[2] = RELAY_FAN_PIN;
  for(int i=0; i<3; i++){
    // Pull up first to prevent relay flicker during startup
    digitalWrite(_relayPins[i], HIGH);
    // Relay trigger pins
    pinMode(_relayPins[i], OUTPUT);
  }
}

void Thermostat::turnAllOff(){
  turnOff(THERMO_HEAT);
  turnOff(THERMO_AC);
  turnOff(THERMO_FAN);
}

boolean Thermostat::turnOn(int type){
  if(isOn(type)) return true;
  if(isWaiting()) return false;
  switch(type){
    case THERMO_HEAT:
      if(isOn(THERMO_AC)){
        turnOff(THERMO_AC);
        return false;
      }
      if(isOn(THERMO_FAN)){
        turnOff(THERMO_FAN);
      }
      _setRelay(THERMO_HEAT,true);
      break;
    case THERMO_AC:
      if(isOn(THERMO_HEAT)){
        turnOff(THERMO_HEAT);
        return false;
      }
      _setRelay(THERMO_AC,true);
      delay(10);
      _setRelay(THERMO_FAN,true);
      break;
    case THERMO_FAN:
      _setRelay(THERMO_FAN,true);
      break;
  }
  return true;
}

void Thermostat::turnOff(int type){
  if(!isOn(type)) return;
  switch(type){
    case THERMO_HEAT:
      _setRelay(THERMO_HEAT,false);
      _setWait(_heatOffDelay);
      break;
    case THERMO_AC:
      _setRelay(THERMO_AC,false);
      _setRelay(THERMO_FAN,false);
      _setWait(_acOffDelay);
      break;
    case THERMO_FAN:
      if(isOn(THERMO_AC)){
        turnOff(THERMO_AC);
      }else{
        _setRelay(THERMO_FAN,false);
      }
      break;
  }
}

boolean Thermostat::isOn(int type){
  return _typeOnOff[type];
}

boolean Thermostat::isWaiting(){
  return (_waitUntil > millis());
}

unsigned long Thermostat::waitingSecLeft(){
  return ((_waitUntil - millis()) / 1000);
}

void Thermostat::serialDebug(boolean enable){
  _debug = enable;
}

const char* Thermostat::typeToName(int type){
  switch(type){
    case THERMO_HEAT:
      return "THERMO_HEAT";
      break;
    case THERMO_AC:
      return "THERMO_AC";
      break;
    case THERMO_FAN:
      return "THERMO_FAN";
      break;
  }
}

unsigned long Thermostat::getLastOnTime(int type){
  return _lastOnTime[type];
}

int Thermostat::getCurrentAction(){
  if(isWaiting()) return ACTION_WAIT;
  if(isOn(THERMO_HEAT)) return ACTION_HEAT;
  if(isOn(THERMO_AC)) return ACTION_AC;
  if(isOn(THERMO_FAN)) return ACTION_FAN;
  return ACTION_OFF;
}

boolean Thermostat::isAction(int action){
  return (getCurrentAction() == action);
}

void Thermostat::_setRelay(int type, boolean onOff){
  if(_debug){
    if(onOff){
      Serial.print("Enabling ");
    }else{
      Serial.print("Disabling ");
    }
    Serial.println(typeToName(type));
  }
  if(onOff) _lastOnTime[type] = millis();
  digitalWrite(_relayPins[type], onOff?LOW:HIGH);
  _typeOnOff[type] = onOff;
}

void Thermostat::_setWait(unsigned long time){
  if(_debug){
    Serial.print("Waiting for ");
    Serial.print(time / 1000);
    Serial.println(" sec");
  }
  _waitUntil = millis() + time;
}

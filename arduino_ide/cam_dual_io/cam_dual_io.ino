#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>

// Using Zephyr overlay as reference
// https://github.com/arduino/ArduinoCore-zephyr/blob/main/variants/arduino_uno_q_stm32u585xx/arduino_uno_q_stm32u585xx.overlay

// J4 
#define CAM0_GPIO_EN 36
#define CAM0_GPIO_LED_EN 36

// J3
#define CAM1_GPIO_EN 47
#define CAM1_GPIO_LED_EN 49

// DSI
#define DSI_GPIO_EN  35
#define DSI_GPIO_RST  37

void setup() {
  // Enabling devices
  // Camera 0
  pinMode(CAM0_GPIO_EN, OUTPUT);
  digitalWrite(CAM0_GPIO_EN, HIGH);
  pinMode(CAM0_GPIO_LED_EN, OUTPUT);
  digitalWrite(CAM0_GPIO_LED_EN, HIGH);
  
  // Camera 1
  pinMode(CAM1_GPIO_EN, OUTPUT);
  digitalWrite(CAM1_GPIO_EN, HIGH);
  pinMode(CAM1_GPIO_LED_EN, OUTPUT);
  digitalWrite(CAM1_GPIO_LED_EN, HIGH);

  // DSI display
  pinMode(DSI_GPIO_EN, OUTPUT);
  digitalWrite(DSI_GPIO_EN, HIGH);
  pinMode(DSI_GPIO_RST, OUTPUT);
  digitalWrite(DSI_GPIO_RST, LOW);
  delay(50);
  digitalWrite(DSI_GPIO_RST, HIGH);
  //delay(50);
  //digitalWrite(DSI_GPIO_RST, LOW);

}

void loop() {
  // put your main code here, to run repeatedly:

}

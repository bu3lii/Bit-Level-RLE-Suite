# Bit-Level-RLE-Suite

Implemented multiple procedures for initialization of the system and functioning of the circuit.

- INIT_8255: Initialization of 8255 PPI with designated control word
- INIT_LCD: Initialization of HD44780 LCD screen for 8 bit data, 2 lines, and 5x8 dot font configuration
- LCD Support Procedures: Clearing, Starting new line, sending data word, sending command word, printing strings
- RLE_ENCODE: Encodes hardcoded bytes of binary into Run Length Encoded Pairs in the form of (bit,run length)

To be done:
- Implementation of 8279 Keyboard and Display Controller
- Physical Circuit Design
- Decoder Procedures
- Interactive Suite

Author:
[@bu3lii](https://github.com/bu3lii)

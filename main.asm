; PORT DEFINITIONS
; 8255 BASE ADDRESS IS 0300H

PORT_A EQU 0300h ; 8255 Port A -> LCD Data Bus (D0-D7)
PORT_B EQU 0301h ; 8255 Port B -> LED Flags Output
PORT_C EQU 0302h ; 8255 Port C -> LCD Control Bits
PORT_CTRL EQU 0303h ; 8255 Control Register

; LCD CONTROL BIT MASKS
LCD_RS EQU 01h ; register select -> 0 = command, 1 = data
LCD_RW EQU 02h ; Read/Write: -> 0 = Write, 1 = Read
LCD_EN EQU 04h ; Enable

; LED FLAG BIT MASKS
LED_ENCODE_DONE EQU 01h ; Bit 0 = encoding complete
LED_ERROR EQU 02h ; Bit 1 = error or size increase flag

.MODEL SMALL
.STACK 100h

.DATA
                  
    ; input bitstream
    input_bits DB 1,1,1,0,0,1,1,0,0,0,0,1
    INPUT_LEN EQU $ - input_bits    ; compiler directive to calculate the size of the input in bytes     
    
    ; output buffer - the max number of pairs is INPUT_LEN*2 since the worst case scenario is alternating bits
    ; Each pair makes up 2 bytes so reserve that much
    output_buffer DB (INPUT_LEN*2) DUP(0FFh) ; fill in with FFh as placeholder
    
  
    ; compression statistics
    input_size DW INPUT_LEN
    output_size DW 0
    
    ; LCD Message Strings
    msg_ready DB 'RLE READY', 0
    msg_done DB  'RLE DONE', 0 
    msg_error DB 'Size Grew!',0
    
    ; variable for bookkeeping later
    pair_count DW 0
    
.CODE
MAIN PROC
    
   MOV AX,@DATA
   MOV DS,AX
   
   CALL INIT_8255
   
   ;CALL INIT_LCD
   
   ;LEA SI, msg_ready
   ;CALL LCD_PRINT_STRING
   
   CALL RLE_ENCODE
   
   MOV AX,pair_count
   SHL AX,1
   MOV output_size,AX
   
   CMP AX,INPUT_LEN
   JLE ENCODE_OK
   
   MOV AL,LED_ERROR
   MOV DX,PORT_B
   OUT DX,AL
   CALL LCD_SECOND_LINE
   LEA SI,msg_error
   CALL LCD_PRINT_STRING
   JMP DONE
   
   
ENCODE_OK:

    MOV AL,LED_ENCODE_DONE
    MOV DX,PORT_B
    OUT DX,AL
    CALL LCD_SECOND_LINE
    LEA SI,msg_done
    CALL LCD_PRINT_STRING
    
DONE:
    MOV AX,4C00h
    INT 21h
MAIN ENDP

              
; INIT_8255 IN MODE 0 WHERE
; Port A -> Output (LCD data)
; Port B -> Output (LED Flags)
; Port C -> Output (LCD Control)
; Control word: 10000000b = 80h
INIT_8255 PROC
    MOV AL,80h
    MOV DX,PORT_CTRL
    OUT DX,AL
    
    MOV AL,00h
    MOV DX,PORT_A
    OUT DX,AL
    MOV DX,PORT_B
    OUT DX,AL
    MOV DX,PORT_C
    OUT DX,AL
    RET
INIT_8255 ENDP 


; INIT_LCD - Standard init sequence, got from the internet and other projects <- IMPORTANT
; Assumes 8 bit, 2 lines, 5x8 font

INIT_LCD PROC
    CALL LCD_DELAY_LONG
    
    MOV AL,38h ; control word 
    CALL LCD_SEND_CMD
    CALL LCD_DELAY_SHORT
    
    ; repeat again, required by HD44680 LCD
    MOV AL,38h
    CALL LCD_SEND_CMD
    CALL LCD_DELAY_SHORT
    
    ; display on, cursor off, blink off
    MOV AL,0Ch
    CALL LCD_SEND_CMD
    CALL LCD_DELAY_SHORT
    
    
    ;clear display
    MOV AL,01h
    CALL LCD_SEND_CMD
    CALL LCD_DELAY_SHORT
    
    ; Entry mode set: increment cursor but no display shift (06h)
    MOV AL,06h
    CALL LCD_SEND_CMD
    CALL LCD_DELAY_SHORT
    
    RET
INIT_LCD ENDP


; LCD_SEND_CMD -> sends command byte in AL to the LCD
; RS = 0 (command), RW = 0 (write), pulse enabled

LCD_SEND_CMD PROC
    PUSH AX
    MOV DX,PORT_A
    OUT DX,AL
    MOV AL,00h
    MOV DX,PORT_C
    OUT DX,AL
    MOV AL,LCD_EN
    OUT DX,AL
    CALL LCD_DELAY_SHORT
    MOV AL,00h
    OUT DX,AL
    CALL LCD_DELAY_SHORT  
    POP AX
    RET
LCD_SEND_CMD ENDP

; LCD_SEND_DATA -> Sends the data byte in al to the LCD
; rs = 1 (data), rw=0 (write), pulse enabled

LCD_SEND_DATA PROC    
    PUSH AX
    MOV DX,PORT_A
    OUT DX,AL
    MOV AL,LCD_RS
    MOV DX,PORT_C
    OUT DX,AL
    MOV AL,05h
    OUT DX,AL
    CALL LCD_DELAY_SHORT
    MOV AL,LCD_RS
    OUT DX,AL
    CALL LCD_DELAY_SHORT 
    POP AX
    RET
LCD_SEND_DATA ENDP

; LCD_PRINT_STRING -> prints a null terminated string

LCD_PRINT_STRING PROC
    PRINT_LOOP:
        MOV AL,[SI]
        CMP AL,0
        JE PRINT_DONE
        CALL LCD_SEND_DATA
        INC SI
        JMP PRINT_LOOP
    PRINT_DONE:
        RET
LCD_PRINT_STRING ENDP

; LCD_SECOND_LINE -> move cursor to start of second line (C0h)

LCD_SECOND_LINE PROC
    MOV AL,0C0h
    CALL LCD_SEND_CMD
    CALL LCD_DELAY_SHORT
    RET
LCD_SECOND_LINE ENDP

; LCD_DELAY_SHORT -> short delay for buffering

LCD_DELAY_SHORT PROC
    PUSH CX
    MOV CX,0100h
SHORT_WAIT:
    LOOP SHORT_WAIT
    POP CX
    RET
LCD_DELAY_SHORT ENDP

; LCD_DELAY_LONG -> same as the proc above but the delay is longer

LCD_DELAY_LONG PROC
    PUSH CX
    MOV CX,0F00h
LONG_WAIT:
    LOOP LONG_WAIT
    POP CX
    RET
LCD_DELAY_LONG ENDP

; RLE_ENCODE <- THE ENCODING PROC (IMPORTANT)
; input: input_bits (DS:SI) and length INPUT_LEN
; output: output_buffer (DS:DI) and the updated pair_count
; Used Registers:
; SI = pointer for input_bits
; DI = pointer for output_buffer
; AL = current bit being counted
; BL = next bit for comparison
; CX = remainign bytes of input
; DH = current run count


RLE_ENCODE PROC
    LEA SI, input_bits
    LEA DI, output_buffer
    MOV CX,INPUT_LEN
    MOV pair_count,0
                      
    ; handling empty input
    CMP CX,0
    JE ENCODE_DONE
    
    ; read first bit then start current run
    
    MOV AL,[SI]
    INC SI
    DEC CX
    MOV DH,1
    
ENCODE_LOOP:
    CMP CX,0
    JE STORE_LAST_PAIR
    
    MOV BL,[SI]
    INC SI
    DEC CX
    
    CMP BL,AL
    JE INCREMENT_RUN
    
    ; BIT CHANGED = STORE THE CURRENT PAIR
    MOV [DI],AL    ; store bit value
    INC DI
    MOV [DI],DH    ; store run count
    INC DI
    INC pair_count    
    
    ; start new run with BL
    MOV AL,BL
    MOV DH,1
    JMP ENCODE_LOOP
    
INCREMENT_RUN:
    INC DH ; extend run
    ; check for overflow just incase, max is 255 for 1 byte
    CMP DH,0FFh
    JNE ENCODE_LOOP
    
    ; if the run hit 255 store the pair and continue the same bit
    MOV [DI],AL
    INC DI
    MOV [DI],DH
    INC DI
    INC pair_count
    MOV DH,0 ; reset count
    JMP ENCODE_LOOP
    
STORE_LAST_PAIR:
    ;store the last run that was in progress
    MOV [DI],AL
    INC DI
    MOV [DI],DH
    INC DI
    INC pair_count
    
ENCODE_DONE:
    RET
RLE_ENCODE ENDP

END MAIN
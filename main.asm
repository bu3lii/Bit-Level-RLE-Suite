; major rewrite because progress report code was too messy to work on, procs were inconsistent and any iteration needed alot of bookkeeping
; this version is much more organized and consistent because I opted for camel case for proc names for the sake of easier development and grouped similar procs
; NOTE: ALL COMPARISONS WILL BE UNSIGNED BECAUSE WE WANT TO HANDLE UNEXPECTED NEGATIVES                          
    ; potrs and their definitions
PORT_A      EQU 0300h
PORT_B      EQU 0302h
PORT_C      EQU 0304h
PORT_CTRL   EQU 0306h

LCD_RS      EQU 01h
LCD_EN      EQU 04h

BTN_ZERO    EQU 20h
BTN_ONE     EQU 40h
BTN_NEXT    EQU 80h
BTN_ALL     EQU 0E0h

LED_OK      EQU 01h
LED_BAD     EQU 02h
MAX_INPUT   EQU 64

.MODEL SMALL    ; masm syntax for proteus
.STACK 100h     ; i used nvim to write this, this was automaticallty generated

.DATA
    input_bits    DB MAX_INPUT DUP(0)
    encoded_bits  DB (MAX_INPUT * 2) DUP(0FFh)   ; in rle the max possible encoded is 2*input, FF is the empty placeholder
    decoded_bits  DB MAX_INPUT DUP(0)

    input_size    DW 0
    pair_count    DW 0
    output_size   DW 0
    decoded_size  DW 0
    verify_ok     DB 0

    page_now      DW 0
    enc_pages     DW 0
    dec_pages     DW 0
    total_pages   DW 0
                                  
                                  
    ; strings for printing on LCD
    msg_input     DB 'Input 0/1 NEXT',0
    msg_len       DB 'LEN:',0
    msg_need      DB 'Enter bits first',0
    msg_full      DB 'Buffer full',0
    msg_ready     DB 'RLE Ready!',0
    msg_next      DB 'Press NEXT',0
    msg_stats     DB 'STATS',0
    msg_in        DB 'IN:',0
    msg_out       DB ' OUT:',0
    msg_enc       DB 'ENC ',0
    msg_decoding  DB 'Decoding...',0
    msg_wait      DB 'Please wait',0
    msg_dec       DB 'DEC ',0
    msg_done      DB 'Done!',0
    msg_pass      DB 'PASS',0
    msg_fail      DB 'FAIL',0
    msg_ok        DB ' SIZE OK',0
    msg_grew      DB ' SIZE GREW',0
    msg_empty     DB '-',0

.CODE

Main PROC
    ; First get the data segment ready, then start the hardware.
    MOV AX,@DATA
    MOV DS,AX
                   
    ;inits
    CALL Setup8255
    CALL SetupLcd

    CALL ReadUserIn     ; user inputs using three pushbuttons
    CALL CompressBits   ; RLE Encoding call

    MOV AX,pair_count
    MOV BX,2         
    MUL BX          ; output is 2*pairs since the symbol takes up a space also
    MOV output_size,AX

    CALL DecompressBits        ; Decode RLE
    CALL CheckResult           ; Verify decoded against original
    CALL CountPages            ; LCD printing helper

    MOV page_now,0     ; init first page
PageLoop:    ; cycle the LCD display pages with the NEXT pushbutton
    CALL ShowPage
    CALL WaitNextPress
    INC page_now      ; move to next page on NEXT
    MOV AX,page_now
    CMP AX,total_pages
    JB PageLoop         ; if there are still more pages go back
    MOV page_now,0      ; if no more pages just cycle back to first page
    JMP PageLoop
Main ENDP
         
         
         
         
         
;--------------

; USER INPUT PROCS AND HELPERS

ReadUserIn PROC         ; main user input loop
    MOV input_size,0
InputLoop:    ; regen the LCD page every time an input is done to reflect the changes
    CALL ShowInputScreen
WaitAnyButton:    ; idle until button press
    CALL ReadButtons
    CMP AL,0            ; if nothing yet loopback
    JE WaitAnyButton
    MOV BL,AL
    CALL WaitBtnRelease
                       
    ; handle all the possible inputs (0,1,next)
    TEST BL,BTN_NEXT
    JNZ NextBtnPress
    TEST BL,BTN_ONE
    JNZ OneBtnPress
    TEST BL,BTN_ZERO
    JNZ ZeroBtnPress
    JMP InputLoop

; DIFFERENT INPUT HANDLERS
ZeroBtnPress:    ; zero button pressed, add 0 to input, wrapper for AddBit
    MOV AL,0
    CALL AddBit
    JMP InputLoop

OneBtnPress:    ; one button pressed, add 1 to input,wrapper for AddBit
    MOV AL,1
    CALL AddBit
    JMP InputLoop ; always return to the input loop until next is pressed

NextBtnPress:
    CMP input_size, 0   ; atleast 1 input to proceed otherwise loopback
    JA InputDone
    LEA SI,msg_need
    CALL ShowNotice
    JMP InputLoop

InputDone:    ; we have at least one bit, so input is finished
    RET
ReadUserIn ENDP

AddBit PROC
    PUSH AX      ; maintain the values in ax,bx,si   code best practices :)
    PUSH BX
    PUSH SI
    MOV BX,input_size
    CMP BX,MAX_INPUT
    JAE InputFull       ; wrap around, JAE is same is JGE but for unsigned, look at top of report for explanation
    LEA SI,input_bits
    ADD SI,BX
    MOV [SI],AL
    INC input_size
    JMP AddBitDone
InputFull:    ; stop at the buffer, 8086 cant take any more
    LEA SI,msg_full
    CALL ShowNotice
AddBitDone:    ; bring bnack the values we pushed earlier, back to the same state
    POP SI
    POP BX
    POP AX
    RET
AddBit ENDP

ShowInputScreen PROC    ; proc to redraw the input screen (LCD), simple, load msg, print, next line, load, print, load number, print
    CALL LcdClear
    LEA SI,msg_input
    CALL LcdText
    CALL LcdLine2
    LEA SI,msg_len
    CALL LcdText
    MOV AX,input_size
    CALL LcdNumber
    RET
ShowInputScreen ENDP

ReadButtons PROC
    ; Buttons are active low, so NOT changes pressed buttons into 1s.
    MOV DX,PORT_C
    IN AL,DX
    NOT AL
    AND AL,BTN_ALL
    RET
ReadButtons ENDP

WaitBtnRelease PROC
    CALL ButtonPause       ; specific button debounce delay
StillPressed:
    CALL ReadButtons
    CMP AL,0
    JNE StillPressed      ; if not 0 its still pressed, keep waiting
    CALL ButtonPause      ; release debounce
    RET
WaitBtnRelease ENDP

WaitNextPress PROC
NextDown:    ; display pages only move when NEXT is pressed
    MOV DX,PORT_C
    IN AL,DX
    TEST AL,BTN_NEXT
    JNZ NextDown
    CALL ButtonPause
NextUp:    ; wait for the user to let go of NEXT
    MOV DX,PORT_C
    IN AL,DX
    TEST AL,BTN_NEXT
    JZ NextUp
    CALL ButtonPause
    RET
WaitNextPress ENDP

ShowNotice PROC         ; warning page just incase
    CALL LcdClear
    CALL LcdText
    CALL LongPause
    CALL LongPause
    RET
ShowNotice ENDP   






;---------------------------
;   RLE PROCS AND HELPERS

CompressBits PROC   ; ENCODING
    LEA SI,input_bits
    LEA DI,encoded_bits
    MOV CX,input_size
    MOV pair_count, 0
    CMP CX,0
    JE CompressDone

    MOV AL,[SI]
    INC SI          ; move up input
    DEC CX          ; move down index
    MOV DH,1

ReadNextBit:    ; iterate thru the input
    CMP CX,0
    JE SaveLastRun   ; if 0, no next bit, end
    MOV BL,[SI]
    INC SI
    DEC CX
    CMP BL,AL        ; if AL(Current) = BL(next)
    JE SameRun        ; icnrement the run

    MOV [DI],AL     ; otherwise move bit symbol
    INC DI
    MOV [DI],DH     ; store run count
    INC DI
    INC pair_count       ; end the run and start over at 1 and BL will be the current bit
    MOV AL,BL
    MOV DH,1
    JMP ReadNextBit

SameRun:    ; same bit as before, so the run gets longer
    INC DH            ; increment run count
    JMP ReadNextBit

SaveLastRun:    ; LAST RUN END
    MOV [DI],AL
    INC DI
    MOV [DI],DH       ; same as the other saves, just do it under this label
    INC DI
    INC pair_count
CompressDone:
    RET
CompressBits ENDP

DecompressBits PROC         ; DECODING
    LEA SI,encoded_bits
    LEA DI,decoded_bits
    MOV CX,pair_count
    MOV decoded_size,0
    CMP CX,0
    JE DecompressDone

ReadNextRun:    ; Read the pair
    MOV AL,[SI]  ; symbol
    INC SI
    MOV BL,[SI]  ; run length
    INC SI

WriteRunBit:    ; use BL as a loop variable, continue to add to decode until run reaches 0
    CMP BL,0
    JE RunDone
    MOV DX,decoded_size
    CMP DX,input_size
    JAE DecodeOverflow     ; overflow safeguard just incase
    MOV [DI],AL
    INC DI
    INC decoded_size
    DEC BL
    JMP WriteRunBit

RunDone:    ; current run ended, just wraps a si increment
    LOOP ReadNextRun
    JMP DecompressDone
DecodeOverflow:    ; juust incase, although very hard to even get to this, if possible please tell me how
    MOV decoded_size, 0FFFFh        ; PLACEHOLDER VALUE __REMEMBER__
DecompressDone:    ; ready for verification
    RET
DecompressBits ENDP

CheckResult PROC        ; verification 
    MOV verify_ok, 0
    MOV AX,decoded_size      ; 1st check: size
    CMP AX,input_size
    JNE CheckDone

    LEA SI,input_bits
    LEA DI,decoded_bits
    MOV CX,input_size
CompareBit:    ; check each bit one buy one
    CMP CX,0        ;loop tewrminate
    JE CheckPassed
    MOV AL,[SI]
    CMP AL,[DI]
    JNE CheckDone
    INC SI
    INC DI
    LOOP CompareBit

CheckPassed:    ; everything matched -> PASS
    MOV verify_ok,1
CheckDone:    ; leave verify_ok as either pass or fail
    RET
CheckResult ENDP
       
       
       
                 
 ;---------------
 ; LCD PAGE MAGIC, SEE BELOW
 ;  Check report for method in text
 
CountPages PROC                          ; ***trick: each page can only show 3 pairs, so divide by 3 and round up by 2 to get total number of pages needed***
    PUSH AX    ; as usual, preserve data
    PUSH BX
    PUSH DX

    MOV AX,pair_count
    ADD AX,2    ; division in assembly rounds down, always round up by 2 no matter what
    MOV BX,3
    XOR DX,DX   ; clear dx because 16 bit div uses dx
    DIV BX
    CMP AX,0    ; safety net for if page count is ever calculated zero, should be impossible but it happened during testing
    JNE EncPagesReady
    MOV AX,1      ; force 1 if it is
EncPagesReady:    ; encoded page count is ready
    MOV enc_pages, AX

    MOV AX,decoded_size
    CMP AX,0FFFFh       ; remember from decode, if overflow we set FFFFh, we handle it here
    JNE DecodeSizeOk
    MOV AX,input_size
DecodeSizeOk:    ; use the decoded size unless overflow was detected
    ADD AX,15    ; SAME LOGIC AS ROUNDUP IN ABOVE, assembly division rounds down, so we round up by adding
    MOV BX,16    ; div by 16 because 16x2 can hold 16 bits per line
    XOR DX,DX
    DIV BX
    CMP AX,0           ; same as above, somehow got zero sometimes so we have to handle it here and force it to 1
    JNE DecPagesReady
    MOV AX,1
DecPagesReady:    ; decoded page count is ready
    MOV dec_pages, AX

    MOV AX,enc_pages      ; variable pages
    ADD AX,dec_pages      ; variable pages
    ADD AX,4              ; add the static pages
    MOV total_pages,AX

    POP DX
    POP BX
    POP AX
    RET
CountPages ENDP

; DIFFERENT PAGES BELOW

ShowPage PROC      ; main page driver proc, remember AX for the static pages, BX for the encoding pages, DX for the decoding pages
    MOV AX, page_now
    CMP AX,0          ; page 0 shows "Ready to RLE! enter"
    JE ReadyPage
    CMP AX,1          ; page 1 shows stats like In:X Out:Y, for comparison sake
    JE StatsPage

    MOV BX,enc_pages
    ADD BX,2         ; encoded pages start at page 2
    CMP AX,BX
    JB EncodedPage   ; if still below, we're still in an encoding page

    CMP AX,BX
    JE DecodingPage    ; dummy waiting screen directly after encoded stream

    MOV DX,BX
    INC DX
    ADD DX,dec_pages    ; DX = decoding dummy wait + 1 + decoded pages
    CMP AX,DX
    JB DecodedPage    ;; still inside decoded section

    JMP DonePage   ; otherwise show final result
    
; -------
; INDIVIDUAL PAGE CONTROLS

ReadyPage:     ; very obvious, clear the screen, load ready message, display, nextline, load next message, call print proc
    CALL LcdClear       
    LEA SI,msg_ready
    CALL LcdText
    CALL LcdLine2
    LEA SI,msg_next
    CALL LcdText
    RET

StatsPage:    ; show input and output size, same as above, just use different procs for printing strings and numbers
    CALL LcdClear
    LEA SI,msg_stats
    CALL LcdText
    CALL LcdLine2
    LEA SI,msg_in
    CALL LcdText
    MOV AX,input_size
    CALL LcdNumber
    LEA SI,msg_out
    CALL LcdText
    MOV AX,output_size
    CALL LcdNumber
    CALL SetLeds
    RET

EncodedPage:   ; REMEMBER: AX has the current page, USE: Show the encoded stuff 
    MOV BX,AX   
    SUB BX,2    ; encoded pages starta t 2, we use 2 as a index here
    CALL ShowEncodedPage
    RET

DecodingPage:    ; dummy wait page, not actually waiting for anything, just for effect
    CALL LcdClear
    LEA SI,msg_decoding
    CALL LcdText
    CALL LcdLine2
    LEA SI,msg_wait
    CALL LcdText
    RET

DecodedPage:    ; REMEMBER, AX IS CURRENT PAGE              show one page of decoded bits
    MOV BX,AX
    SUB BX,enc_pages  ; remove encoded pages from count
    SUB BX,3          ; remove ready, stats and dummy wait pages from count
    CALL ShowDecodedPage
    RET

DonePage:    ; final page with pass/fail status
    CALL LcdClear
    LEA SI,msg_done
    CALL LcdText
    CALL LcdLine2
    CMP verify_ok,1    ; if verification passed it will print ok
    JE ResultPassed
    LEA SI,msg_fail    ; otherwise a fail message
    CALL LcdText
    RET

ResultPassed:    ; decoded bits matched the original input so shows pass message
    LEA SI,msg_pass
    CALL LcdText
    MOV AX,output_size
    CMP AX,input_size
    JA ResultGrew           ; size compare
    LEA SI,msg_ok
    CALL LcdText
    RET
ResultGrew:    ; compression worked, but output became bigger
    LEA SI,msg_grew
    CALL LcdText
    RET
ShowPage ENDP

ShowEncodedPage PROC   ; shows the actual encoded pairs on the LCD, printing in parts
    PUSH AX     ; preserve all the registers. coding best practcie
    PUSH BX
    PUSH CX
    CALL LcdClear
    LEA SI,msg_enc    ; "ENC:"
    CALL LcdText
    MOV AX,BX        ; BX holds encoded page index, move it here
    INC AX
    CALL LcdNumber         
    MOV AL,'/'
    CALL LcdChar           ; NOW LOOKS LIKE "ENC:X/
    MOV AX,enc_pages
    CALL LcdNumber         ; NOW LOOKS LIKE "ENC:X/Y", acts as a dynamic page counter
    MOV AL,':'
    CALL LcdChar          ; Now : "ENC:X/Y:"
    CALL LcdLine2
    MOV AX,BX        ; remember, BX = encoded page index
    MOV CX,3
    MUL CX        ; each page can hold 3 pairs, meaning AX = encoded page index * 3
    MOV BX,AX    ; store the first pair to print in BX
    CALL PrintEncodedPairs
    POP CX
    POP BX
    POP AX            ; return values we pushed earlier
    RET
ShowEncodedPage ENDP

ShowDecodedPage PROC        ; EXACT SAME AS PROC ABOVE, DIFFERENCE IS 16 BITS PER PAGE AND PRINTS "DEC"
    PUSH AX
    PUSH BX
    PUSH CX
    CALL LcdClear
    LEA SI,msg_dec
    CALL LcdText
    MOV AX,BX
    INC AX
    CALL LcdNumber
    MOV AL,'/'
    CALL LcdChar
    MOV AX,dec_pages
    CALL LcdNumber
    MOV AL,':'
    CALL LcdChar
    CALL LcdLine2
    MOV AX,BX
    MOV CX,16
    MUL CX
    MOV BX,AX
    CALL PrintDecodedBits
    POP CX
    POP BX
    POP AX
    RET
ShowDecodedPage ENDP

PrintEncodedPairs PROC
    PUSH AX          ; again, preserve values
    PUSH BX
    PUSH CX
    PUSH SI
    MOV AX,pair_count
    CMP BX,AX
    JB PairDataExists   ; if this is false, there are no more btis to print
    LEA SI,msg_empty
    CALL LcdText
    JMP PairsDone

PairDataExists:    ; there are still encoded pairs to print
    LEA SI,encoded_bits     ; point to start of encoded
    MOV AX,BX
    MOV DX,2   ; each pair is 2 bytes
    MUL DX     ; AX = pair index * 2 because of 2 bytes per
    ADD SI,AX  ; add offset to SI now SI points at pair
    MOV CX,pair_count
    SUB CX,BX         ; cx holds total pairs, so subtracting BX sees how many left
    CMP CX,3         ; if theres 3 or less pairs print the last few
    JBE PrintPair
    MOV CX,3        ; cap to 3 pairs max if not less
PrintPair:    ; print up to three value:run pairs on the line
    MOV AL,[SI]
    ADD AL,'0'   ; same as ADD AL,30h
    CALL LcdChar
    INC SI
    MOV AL,':'
    CALL LcdChar
    MOV AL,[SI]
    MOV AH,0    ; clear the garbage in AH before printing content of AL
    CALL LcdNumber
    INC SI
    MOV AL,' '   ; space between pairs
    CALL LcdChar
    LOOP PrintPair

PairsDone:    ; finished printing encoded pairs for this page
    POP SI
    POP CX        ; return all preserved values
    POP BX
    POP AX
    RET
PrintEncodedPairs ENDP

PrintDecodedBits PROC
    PUSH AX
    PUSH BX            ; preserve values
    PUSH CX
    PUSH SI
    MOV AX,decoded_size
    CMP AX,0FFFFh
    JNE DecodedSizeGood
    MOV AX,0               ; if overflowed, dont print anything
DecodedSizeGood:
    CMP BX,AX
    JB BitDataExists
    LEA SI,msg_empty
    CALL LcdText
    JMP BitsDone

BitDataExists:    ; helper to see if any decoded bits remain, equiv to PairDataExists
    LEA SI,decoded_bits
    ADD SI,BX         ; BX already holds bit index before calling this, so add to SI to point to the bit
    MOV CX,AX         ; AX = total bits
    SUB CX,BX         ; how many bits remain (for loop)
    CMP CX,16
    JBE PrintBit
    MOV CX,16
    
PrintBit:    ; print up to sixteen decoded bits
    MOV AL,[SI]
    ADD AL,'0'
    CALL LcdChar
    INC SI
    LOOP PrintBit

BitsDone:    ; finished printing decoded bits for this page
    POP SI
    POP CX
    POP BX
    POP AX
    RET
PrintDecodedBits ENDP

SetLeds PROC
    MOV AX,output_size
    CMP AX,input_size
    JA BadLed
    MOV AL,LED_OK             ; lughts up either the grow or shrink LED, simple
    MOV DX,PORT_B
    OUT DX,AL
    RET
BadLed:    ; encoded output is bigger, so light the bad LED
    MOV AL,LED_BAD
    MOV DX,PORT_B
    OUT DX,AL
    RET
SetLeds ENDP
    
    
    
;-----------
; INITS AND LCD HELPERS

Setup8255 PROC      ; proc to init 8255 with control word 88h, DX is used because emu does not allow direct addressing > 255
    MOV DX,PORT_CTRL                                                ; our addresses are 300h and above
    MOV AL,88h
    OUT DX,AL
    MOV AL,0
    MOV DX,PORT_A
    OUT DX,AL
    MOV DX,PORT_B
    OUT DX,AL
    MOV DX,PORT_C
    OUT DX,AL
    RET
Setup8255 ENDP

SetupLcd PROC            ; mainly from datasheets, LCD expects this sequence
    CALL LongPause
    CALL LongPause
    MOV AL,30h       ; sets up 8 bit interface multiple times to ensure good start state
    CALL LcdCmd
    CALL LongPause
    MOV AL,30h
    CALL LcdCmd
    CALL LongPause
    MOV AL,30h
    CALL LcdCmd
    CALL LongPause
    MOV AL,38h        ; init 8 bit interface, 2 lines, 5x8 dot font display
    CALL LcdCmd
    CALL LongPause
    MOV AL,0Ch         ; display on cursor off
    CALL LcdCmd
    CALL LongPause
    CALL LcdClear
    MOV AL,06h          ; entry mode, now the LCD is correctly initiated
    CALL LcdCmd
    CALL LongPause
    RET
SetupLcd ENDP

LcdClear PROC
    MOV AL,01h      ; command word for clearing display, wrapped in proc for easy call
    CALL LcdCmd
    CALL ClearPause
    RET
LcdClear ENDP

LcdLine2 PROC
    MOV AL,0C0h       ; command word for a newline
    CALL LcdCmd
    CALL LongPause
    RET
LcdLine2 ENDP

LcdCmd PROC
    PUSH AX         ; preserve values
    PUSH DX
    MOV DX,PORT_A
    OUT DX,AL
    MOV DX,PORT_C
    MOV AL,0        ; RS = 0 for command register
    OUT DX,AL
    CALL TinyPause
    MOV AL,LCD_EN     ; EN pulse so LCD reads command word
    OUT DX,AL
    CALL TinyPause
    MOV AL,0          ; end the pulse
    OUT DX,AL
    CALL LongPause
    POP DX
    POP AX
    RET
LcdCmd ENDP

LcdChar PROC
    PUSH AX
    PUSH DX
    MOV DX,PORT_A     ; send the character in AL to data
    OUT DX,AL
    MOV DX,PORT_C
    MOV AL,LCD_RS   ; RS =1 for  data register
    OUT DX, AL
    CALL TinyPause
    MOV AL,LCD_RS+LCD_EN   ; pulse enable with rs high
    OUT DX, AL
    CALL TinyPause
    MOV AL,LCD_RS   ; en low again
    OUT DX, AL
    CALL LongPause
    POP DX
    POP AX
    RET
LcdChar ENDP

LcdText PROC    ; RESPONSIBLE FOR PRINTING STRINGS
NextChar:
    MOV AL,[SI]   ; SI will be already pointed to the start of the string
    CMP AL,0
    JE TextDone
    CALL LcdChar    ; loop to print all the characters 1 by 1 until there are a placeholder 0 is reached
    INC SI
    JMP NextChar
TextDone:    ; finished printing this string
    RET
LcdText ENDP

LcdNumber PROC      ; same as above but for printin numbers
    PUSH AX
    PUSH BX           ; preserve all values, this is used frequently so instead of tracking what is being used just preserve all values
    PUSH CX
    PUSH DX
    CMP AX,0          ; is 0 just print it, dont bother converting
    JNE NumberNotZero
    MOV AL,'0'
    CALL LcdChar
    JMP NumberDone
NumberNotZero:    ; split the number into decimal digits
    MOV BX, 10
    MOV CX, 0
TakeDigit:    ; take digits off backwards using divide by 10, see "itoa" algorithm online
    XOR DX, DX
    DIV BX
    PUSH DX    ; save the digit because its the last one
    INC CX
    CMP AX, 0
    JNE TakeDigit
ShowDigit:    ; print the saved digits in the correct order
    POP DX         ; popping fromt he top of the stack will give us the correct order
    ADD DL,'0'  ; convert from digit to ascii, same as adding 30h
    MOV AL,DL       ; stoire in DL because LcdChar uses AL
    CALL LcdChar
    LOOP ShowDigit
NumberDone:    ; finished printing the number
    POP DX
    POP CX         ; return all the preserved values
    POP BX
    POP AX
    RET
LcdNumber ENDP
              
              
                        
                        
                        
;----------------------
; TIMER DELAY PROCEDURES - these numbers were more from experimentation than anything, 
;                           a number too high made the circuit feel unresponsive, number too low made wrong inputs

TinyPause PROC            ; short delay for pulsing
    PUSH CX
    MOV CX, 0100h
TinyLoop:    
    LOOP TinyLoop
    POP CX
    RET
TinyPause ENDP

ButtonPause PROC       ; delay for button debounce
    PUSH CX
    MOV CX, 0FFFFh
ButtonLoop:
    LOOP ButtonLoop
    POP CX
    RET
ButtonPause ENDP

LongPause PROC       ; longer delay for LCD commands
    PUSH CX
    MOV CX, 1800h
LongLoop:
    LOOP LongLoop
    POP CX
    RET
LongPause ENDP

ClearPause PROC       ; ADDED 4/5:  clear was having issues, screen was not being cleared all the way before display redraws
    PUSH CX
    MOV CX, 4000h
ClearLoop:
    LOOP ClearLoop
    POP CX
    RET
ClearPause ENDP

END Main

;	Cerradura electrónica; la interfaz con el usuario se realiza con
;	un teclado matricial y un display LCD. Permite, además de abrir y
;	cerrar una cerradura con algún tipo de relé/electroimán, el cambio
;	de contraseña, la cual se guarda de forma permanente en EEPROM. La
;	contraseña por defecto es 123456. Se utiliza el pin RD7 para comu-
;	nicar el estado a el actuador de la cerradura. El PORTB se utiliza
;	para el teclado matricial utilizando la interrupción RBINT.
;	Utiliza EEPROM con un display LCD 16x2 en modo de operación 4 bits,
;	utilizando flag de busy para saber cuando el display está listo para
;	recibir datos y así imprimir mensajes predeterminados en memoria.
;
;	            PIC16F877A, DIP-40                                   
;	            +------------------U------------------+             
;	       -> 1 | ~MCLR/VPP                   PGD/RB7 |40 <>        
;	       <> 2 | RA0/AN0                     PGC/RB6 |39 <> COL2   
;	       <> 3 | RA1/AN1                         RB5 |38 <> COL1   
;	       <> 4 | RA2/AN2/VREF-                   RB4 |37 <> COL0   
;	       <> 5 | RA3/AN3/VREF+               PGM/RB3 |36 <> FIL3   
;	       <> 6 | RA4/T0CKI                       RB2 |35 <> FIL2   
;	       <> 7 | RA5/AN4/~SS                     RB1 |34 <> FIL1   
;	       <> 8 | RE0/~RD/AN5                 INT/RB0 |33 <> FIL0   
;	       <> 9 | RE1/~WR/AN6                     VDD |32 <- +5V    
;	       <> 10| RE2/~CS/AN7                     VSS |31 <- GND    
;	   +5V -> 11| VDD                        PSP7/RD7 |30 -> ~LOCK  
;	   GND -> 12| VSS                        PSP6/RD6 |29 <>        
;	  XTAL -> 13| OSC1                       PSP5/RD5 |28 <>        
;	 20MHz <- 14| OSC2                       PSP4/RD4 |27 <>        
;	   DB4 <- 15| RC0/T1OSO/T1CKI           DT/RX/RC7 |26 -> RW     
;	   DB5 <- 16| RC1/T1OSI/CCP2            CK/TX/RC6 |25 -> RS     
;	   DB6 <- 17| RC2/CCP1                    SDO/RC5 |24 -> E      
;	   DB7 <> 18| RC3/SCK/SCL             SDA/SDI/RC4 |23 <>        
;	       <> 19| RD0/PSP0                   PSP3/RD3 |22 <>        
;	       <> 20| RD1/PSP1                   PSP2/RD2 |21 <>        
;	            +-------------------------------------+             
;
;	RC3 lleva pull-up ya que es de donde leo el flag de busy, y
;	cuando el display está deshabilitado la salida del flag de busy
;	se pone a HI-Z. E lleva pull-down para que el display no se ha-
;	bilite cuando el PIC está en reset. Se configuran RC0-RC2 como
;	entradas cuando se lee el flag de busy del display, ya que to-
;	dos los pines del display se convierten en salidas y puede pro-
;	ducirse un corto. Estos pines quedan en HI-Z pero como no se
;	pregunta por su valor y se limpian antes de ser escritos no es
;	algo crítico de solucionar.

PROCESSOR 16F877A

CONFIG FOSC	=  HS		; Oscilador 20MHz
CONFIG WDTE	= OFF		; WDT desactivado
CONFIG PWRTE	= OFF		; PWRT desactivado
CONFIG BOREN	=  ON		; BOD activado
CONFIG LVP	= OFF		; RB3 como I/O
CONFIG CPD	= OFF		; Protección de datos desactivada
CONFIG CP	= OFF		; Protección de código desactivada
CONFIG WRT	= OFF		; Deshabilito escritura de código con EECON
CONFIG DEBUG	= OFF		; Deshabilito Debugging, RB6 y RB7 como I/O

#include <xc.inc>

; Registros de memoria de datos compartidos entre bancos
FLAGS		equ		0x70
DEBOUNCE_TEST	equ		0			; con este flag señalo si pregunto por rebote del teclado
MCLR_RESET	equ		1			; con este flag señalo si hubo reset manual, tal que no se inicialice nuevamente el LCD
NEW_KEY		equ		2			; con este flag señalo si se recibió una nueva tecla válida en el teclado
W_AUX		equ		0x71
STATUS_AUX	equ		0x72

main:

		psect	por_vec, global, abs, ovrld, delta=2, class=CODE
		ORG	0x00

; Rutina principal

		CALL		init
loop:		CALL		work
		GOTO		loop

		psect	int_vec, global, abs, ovrld, delta=2, class=CODE
		ORG	0x04

; Interrupción

int:		CALL		ctxt_save
		BCF		STATUS, 5		; me paso al banco 0
		BCF		STATUS, 6
		BTFSC		INTCON, 0		; si saltó RBINT...
			CALL		rbi_handler
		BTFSC		INTCON, 2
			CALL		t0i_handler	; si saltó TMR0...
		CALL		ctxt_rest
		RETFIE

ctxt_save:	MOVWF		W_AUX			; no uso FSR/INDF en la interrupción por lo que no necesito guardarlo
		SWAPF		STATUS, W
		MOVWF		STATUS_AUX
		RETURN

ctxt_rest:	SWAPF		STATUS_AUX, W
		MOVWF		STATUS
		SWAPF		W_AUX, F
		SWAPF		W_AUX, W
		RETURN

rbi_handler:	BTFSS		FLAGS, DEBOUNCE_TEST	; todavía no pregunto por rebote
			CALL		debounce_start	; recibí una tecla, habilito preguntar por rebote
		BTFSC		FLAGS, DEBOUNCE_TEST	; estaba preguntando por rebote y todavía no pasó el tiempo fijado por TMR0
			CALL		debounce_fail	; recibí una tecla y resultó ser un rebote
		MOVLW		(1 << DEBOUNCE_TEST)	; sin importar si estaba preguntando por rebote o no, cuando salta RBINT este flag se invierte
		XORWF		FLAGS, F		; lo modifico aquí en vez de en debounce_start o debounce_fail porque sino se llamaría a ambas subrutinas
		MOVF		PORTB, F		; actualizo PORTB para bajar flag
		BCF		INTCON, 0		; apago flag
		RETURN

DEBOUNCE_COUNT	equ		0x20			; aquí guardo cuántas veces saltó TMR0 mientras que testeaba por rebote

t0i_handler:	CLRF		TMR0
		BCF		INTCON, 2		; reinicio TMR0
		INCF		DEBOUNCE_COUNT, F	; si saltó TMR0 incremento un contador
		MOVLW		7
		XORWF		DEBOUNCE_COUNT, W
		BTFSS		STATUS, 2		; si el contador llegó a 7, quiere decir que TMR0 saltó 8 veces, o sea que pasaron ~100mS
			RETURN
		BCF		FLAGS, DEBOUNCE_TEST	; ya no testeo rebote, recibí pulsación válida
		BCF		INTCON, 5		; ya no salta TMR0
		CALL		get_keycode		; leo tecla
		MOVF		KEYCODE, W
		SUBLW		11
		BTFSS		STATUS, 0		; pregunto si la tecla es menor o igual a 11, si no es así no es una tecla válida
			RETURN
		CALL		kycod_to_ascii		; traduzco el código de tecla al caracter ASCII que le corresponde
		MOVWF		KEY_ASCII
		BSF		FLAGS, NEW_KEY		; aviso que se recibió una nueva tecla válida
		RETURN

debounce_start:	BCF		INTCON, 2
		BSF		INTCON, 5		; permito que salte TMR0
		CLRF		TMR0			; limpio TMR0 para contar ~13mS
		CLRF		DEBOUNCE_COUNT		; limpio el registro que cuenta cuántas veces saltó TMR0
		RETURN

debounce_fail:	BCF		INTCON, 2
		BCF		INTCON, 5		; ya no salta TMR0
		RETURN

KEYCODE		equ		0x21			; aquí guardo el código de tecla que se leyó del teclado
KEY_ASCII	equ		0x22			; tecla recibida en ASCII

get_keycode:	; recibo en KEYCODE el índice de tecla presionado
		CLRF		KEYCODE
		SWAPF		PORTB, W
		CALL		filcol_table
		ADDWF		KEYCODE, F
		BSF		STATUS, 5
		SWAPF		TRISB, F
		BCF		STATUS, 5
		CLRF		PORTB
		MOVLW		0x0F
		XORWF		PORTB, W
		CALL		filcol_table
		ADDWF		KEYCODE, F
		BSF		STATUS, 5
		SWAPF		TRISB, F
		BCF		STATUS, 5
		CLRF		PORTB
		MOVF		PORTB, F
		BCF		INTCON, 0
		RETURN

		psect	fun_vec, global, abs, ovrld, delta=2, class=CODE
		ORG	0x50

; Subrutinas

init:		BCF		FLAGS, MCLR_RESET	; asumo por defecto que no hubo reset manual
		BSF		STATUS, 5
		MOVLW		0xF0
		MOVWF		TRISB			; nibble superior como entradas, nibble inferior como salidas (para usar teclado matricial)
		CLRF		TRISC			; todo el puerto como salida
		MOVLW		0x7F
		MOVWF		TRISD			; RD7 como salida
		MOVLW		00000111B
		MOVWF		OPTION_REG		; pull-ups internos activados, prescaler en 1:256
		BSF		STATUS, 6
		CLRF		EECON1			; inicializo control de EEPROM, apunto a EEPROM de datos
		BCF		STATUS, 6
		BSF		PCON, 0
		BTFSC		PCON, 1			; pregunto si hubo reset manual
			BSF		FLAGS, MCLR_RESET	; si hubo reset manual, no llamo init_lcd porque ya está inicializado
		BSF		PCON, 1			; si no hubo reset manual, dejo el flag MCLR_RESET en 0, si hubo power on reset, debo modificar el flag manualmente
		BCF		STATUS, 5
		CLRF		PORTB			; pongo todas las salidas (filas) en 0
		CLRF		PORTC			; inicializo el puerto, enable apagado
		CLRF		PORTD			; mantengo la cerradura cerrada
		BSF		PORTC, RW		; activo lectura
		BTFSS		FLAGS, MCLR_RESET	; si hubo reset manual, no llamo init_lcd porque ya está inicializado
			CALL		init_lcd		; inicializo LCD
		CALL		clear_lcd		; limpio LCD
		BCF		FLAGS, DEBOUNCE_TEST	; por defecto no estoy preguntando por rebote; debe presionarse una tecla primero
		BCF		FLAGS, MCLR_RESET
		BCF		FLAGS, NEW_KEY		; este flag se usa para avisar a los estados que se presionó una tecla, venimos de RESET por lo que debe estar en 0
		; las interrupciones se inicializan en el estado de reset
		MOVLW		RESET_ST
		MOVWF		STATE
		RETURN

; Subrrutinas LCD

LCD_DATA	equ		0x30			; aquí guardo el dato a enviar al LCD

E		equ		5			; pines de PORTC que se usan con el LCD
RS		equ		6
RW		equ		7

init_lcd:	; realizo operaciones necesarias para inicializar el display
		BSF		STATUS, 5
		MOVLW		0x0F
		XORWF		TRISC, F		; DB4-DB7 como entradas
		BCF		STATUS, 5
		BTFSC		PORTC, 3		; pregunto si busy = 0
			GOTO		($-1)&0x7FF	; loopeo, cuando el display termina de resetear pone busy en 0
		BSF		STATUS, 5
		MOVLW		0x0F
		XORWF		TRISC, F		; DB4-DB7 como salidas
		BCF		STATUS, 5
		MOVLW		0x20			; seteo modo 4 bits
		MOVWF		LCD_DATA
		CALL		send_lcd_inst
		MOVLW		0x28			; seteo modo 4 bits, dos líneas, fuente 5x8
		MOVWF		LCD_DATA
		CALL		wait_lcd_inst
		CALL		send_lcd_inst
		MOVLW		0x0E			; display ON, cursor ON, blinking ON
		MOVWF		LCD_DATA
		CALL		wait_lcd_inst
		CALL		send_lcd_inst
		MOVLW		0x06			; incremento hacia derecha, no shifteo todo el display
		MOVWF		LCD_DATA
		CALL		wait_lcd_inst
		CALL		send_lcd_inst
		RETURN

send_lcd_ram:	; mando un dato a la RAM del LCD, guardo previamente dato en LCD_DATA
		BSF		PORTC, RS		; apunto a registro de datos
		CALL		send_lcd_data
		RETURN

send_lcd_inst:	; mando una instrucción al LCD, guardo previamente código de instrucción en LCD_DATA
		BCF		PORTC, RS		; apunto a registro de instrucciones
		CALL		send_lcd_data
		RETURN

send_lcd_data:	; mando un dato guardado en LCD_DATA al LCD, si se interpreta como instrucción o memoria
		; depende de RS (seteados en send_lcd_ram o send_lcd_inst)
		BCF		PORTC, RW		; desactivo lectura
		MOVLW		0xF0			; limpio bits a utilizar en escritura
		ANDWF		PORTC, F
		SWAPF		LCD_DATA, F		; primero envío nibble superior
		MOVLW		0x0F
		ANDWF		LCD_DATA, W		; enmascaro primeros 4 bits (DB7-DB4, dado el SWAPF)
		IORWF		PORTC, F		; enmascaro sobre bits de escritura
		BSF		PORTC, E		; pulso de enable
		NOP
		BCF		PORTC, E
		MOVLW		0xF0			; limpio bits a utilizar en escritura
		ANDWF		PORTC, F
		SWAPF		LCD_DATA, F		; envío nibble inferior
		MOVLW		0x0F
		ANDWF		LCD_DATA, W		; enmascaro primeros 4 bits (DB3-DB0)
		IORWF		PORTC, F		; enmascaro sobre bits de escritura
		BSF		PORTC, E		; pulso de enable
		NOP
		BCF		PORTC, E
		BSF		PORTC, RW		; activo lectura
		RETURN

CONT		equ		0x31			; registro contador para mini rutina de retardo

wait_lcd_ram:	; si tengo que mandar un dato a RAM, tengo que esperar a que el flag de busy baje
		; a 0 y luego esperar un tiempo adicional a que el adress counter del display se
		; establezca en la posición que le corresponde
		CALL		wait_lcd_proc
		MOVLW		5
		MOVWF		CONT
		DECFSZ		CONT, F			; rutina de retardo "inline", ~2uS
			GOTO		($-1)&0x7FF
		RETURN

wait_lcd_inst:	; si tengo que ejecutar una instrucción, apenas el flag de busy quede en 0 ya puedo 
		; procesarla
wait_lcd_proc:	; espero a que termine de procesar el LCD, se detecta cuando el flag de busy se limpia
		BCF		PORTC, RS		; apunto a registro de instrucciones, tal que puedo leer flag de busy
		BSF		STATUS, 5
		MOVLW		0x0F
		XORWF		TRISC, F		; DB4-DB7 como entradas
		BCF		STATUS, 5
		BSF		PORTC, E		; pulso de enable inicial (leo BF)
		NOP
		BCF		PORTC, E		; (*) loop de pulsos
		NOP
		BSF		PORTC, E		; pulso de enable secundario (leo AC3)
		NOP
		BCF		PORTC, E		; pulso de enable
		NOP
		BSF		PORTC, E		; pulso de enable iterado (leo BF)
		NOP
		BTFSC		PORTC, 3		; pregunto si busy = 0
			GOTO		($-9)&0x7FF	; loopeo pulso de enable y pregunto estado de busy (*)
		BCF		PORTC, E
		NOP
		BSF		PORTC, E		; pulso de enable secundario (leo AC3)
		NOP
		BCF		PORTC, E		; queda enable deshabilitado
		BSF		STATUS, 5
		MOVLW		0x0F
		XORWF		TRISC, F		; DB4-DB7 como salidas
		BCF		STATUS, 5
		RETURN

clear_lcd:	; se limpia todo el display LCD y retorna a la posición original
		MOVLW		0x01
		MOVWF		LCD_DATA
		CALL		wait_lcd_inst
		CALL		send_lcd_inst
		RETURN

return_lcd:	; se retorna a la posición original
		MOVLW		0x80 | 0x00
		MOVWF		LCD_DATA
		CALL		wait_lcd_inst
		CALL		send_lcd_inst
		RETURN

; Rutinas de máquina de estados

STATE		equ		0x40			; estado actual
NXT_STATE	equ		0x41			; estado al cual se transiciona

RESET_ST	equ		0			; lista de todos los estados
RESET_TO_CLOSED	equ		1
CLOSED		equ		2
CLOSE_TO_READ	equ		3
READ		equ		4
READ_TO_CO_RD	equ		5
CO_RD		equ		6
CO_RD_TO_READ	equ		7
CO_RD_TO_FAIL	equ		8
FAIL		equ		9
FAIL_TO_CLOSED	equ		10
CO_RD_TO_SUCC	equ		11
SUCC		equ		12
SUCC_TO_OPEN	equ		13
OPEN		equ		14
OPEN_TO_CLOSE	equ		15
OPEN_TO_CHANGE	equ		16
CHANGE		equ		17
CHANGE_TO_CO_CH	equ		18
CO_CH		equ		19
CO_CH_TO_CHANGE	equ		20
CO_CH_TO_NEW	equ		21
NEW		equ		22
NEW_TO_OPEN	equ		23

		psect	work_switch, global, abs, ovrld, delta=2, class=CODE
		ORG	0x100

RAM_PWD_INDEX	equ		0x42			; guardo el índice de la dirección de contraseña que se usa actualmente
RAM_PWD		equ		0x43			; buffer de contraseña, abarca de 0x43 a 0x43+PWD_LENGHT
PWD_LENGHT	equ		6

work:		; switcheo entre los distintos estados, deben estar en orden numérico
		MOVLW		high(work)
		MOVWF		PCLATH
		BCF		STATUS, 0
		RLF		STATE, W
		ADDWF		PCL, F
		CALL		st_rs
		RETURN
		CALL		st_rs_to_cl
		RETURN
		CALL		st_cl
		RETURN
		CALL		st_cl_to_rd
		RETURN
		CALL		st_rd
		RETURN
		CALL		st_rd_to_cr
		RETURN
		CALL		st_cr
		RETURN
		CALL		st_cr_to_rd
		RETURN
		CALL		st_cr_to_fl
		RETURN
		CALL		st_fl
		RETURN
		CALL		st_fl_to_cl
		RETURN
		CALL		st_cr_to_su
		RETURN
		CALL		st_su
		RETURN
		CALL		st_su_to_op
		RETURN
		CALL		st_op
		RETURN
		CALL		st_op_to_cl
		RETURN
		CALL		st_op_to_ch
		RETURN
		CALL		st_ch
		RETURN
		CALL		st_ch_to_cc
		RETURN
		CALL		st_cc
		RETURN
		CALL		st_cc_to_ch
		RETURN
		CALL		st_cc_to_nw
		RETURN
		CALL		st_nw
		RETURN
		CALL		st_nw_to_op
		RETURN

st_rs_to_cl:
st_cl_to_rd:
st_rd_to_cr:
st_cr_to_rd:
st_cr_to_fl:
st_fl_to_cl:
st_cr_to_su:
st_su_to_op:
st_op_to_cl:
st_op_to_ch:
st_ch_to_cc:
st_cc_to_ch:
st_cc_to_nw:
st_nw_to_op:	; se imprimen los mensajes de transición entre estados, todas estas subrutinas hacen lo mismo
		CALL		eeprm_read_it		; leo de la dirección de EEPROM fijada e incremento dirección para un futuro
		IORLW		0			; si devolvió 0, recibí un valor y debo seguir leyendo
		BTFSS		STATUS, 2		; si devolvió 1, recibí 0xFF y termino de leer
			GOTO		($+16)&0x7FF	; termino de leer (*)
		BSF		STATUS, 6
		MOVF		EEDATA, W		; levanto dato leído de RAM
		BCF		STATUS, 6
		MOVWF		LCD_DATA		; paso dato a registro de escritura de LCD
		MOVF		LCD_DATA, F		; pruebo si el dato fue 0
		BTFSC		STATUS, 2
			GOTO		($+4)&0x7FF	; si el dato fue 0, paso a la 2da línea (+)
		CALL		wait_lcd_ram		; si el dato es un caracter ASCII escrito en EEPROM, lo mando al LCD
		CALL		send_lcd_ram
		RETURN
		MOVLW		0x80 | 0x40		; (+) aviso al display que cambie de línea
		MOVWF		LCD_DATA
		CALL		wait_lcd_inst
		CALL		send_lcd_inst
		RETURN
		MOVF		NXT_STATE, W		; (*) paso al estado al que debo transicionar
		MOVWF		STATE
		MOVF		PORTB, F
		BCF		INTCON, 0		; apago flag de RBINT si es que saltó cuando no debía
		BSF		INTCON, 3		; habilito interrupción de RBINT, todos los estados fijos dependen del teclado matricial
		RETURN

st_rs:		CLRF		RAM_PWD_INDEX		; limpio índice de buffer de contraseña
		MOVLW		EEPRM_RS_TO_CL
		CALL		eeprm_init_rd		; inicializo EEPROM
		MOVLW		RESET_TO_CLOSED
		MOVWF		STATE			; paso a transición entre RESET y CLOSED
		MOVLW		CLOSED
		MOVWF		NXT_STATE		; aviso que el siguiente estado será CLOSED
		MOVF		PORTB, F
		MOVLW		10000000B
		MOVWF		INTCON			; habilito interrupciones globales pero ninguna particular
		RETURN

st_cl:		; espero hasta que se presione una tecla para pasar a ingresar contraseña
		SLEEP
		NOP
		BTFSS		FLAGS, NEW_KEY		; recibí nueva tecla con RBINT?
			RETURN
		BCF		FLAGS, NEW_KEY		; limpio flag
		BCF		INTCON, 3		; como paso a una transición, deshabilito el teclado hasta que se imprima mensaje
		MOVLW		EEPRM_CL_TO_RD
		CALL		eeprm_init_rd		; inicializo EEPROM
		MOVLW		CLOSE_TO_READ
		MOVWF		STATE			; paso a transición entre CLOSED y READ
		MOVLW		READ
		MOVWF		NXT_STATE		; aviso que el siguiente estado será READ
		CALL		clear_lcd		; limpio LCD para imprimir mensaje nuevo
		RETURN

st_rd:		; espero hasta que se presione una tecla y la guardo en el buffer de contraseña; cuando el buffer se llena,
		; pregunto si el contenido del buffer coincide con la contraseña guardada en EEPROM
		SLEEP
		NOP
		BTFSS		FLAGS, NEW_KEY		; recibí nueva tecla con RBINT?
			RETURN
		BCF		FLAGS, NEW_KEY		; limpio flag
		BCF		INTCON, 3
		MOVLW		RAM_PWD
		ADDWF		RAM_PWD_INDEX, W
		MOVWF		FSR			; apunto a RAM_PWD + INDEX con FSR
		MOVF		KEY_ASCII, W
		MOVWF		INDF			; sobreescribo esa dirección con la tecla recibida
		MOVWF		LCD_DATA		; imprimo tecla recibida en el LCD
		CALL		wait_lcd_ram
		CALL		send_lcd_ram
		INCF		RAM_PWD_INDEX, F	; incremento el índice para atacar la siguiente posición
		MOVF		RAM_PWD_INDEX, W
		XORLW		PWD_LENGHT		; pregunto si el índice llegó a su valor máximo + 1
		MOVF		PORTB, F
		BCF		INTCON, 0
		BSF		INTCON, 3
		BTFSS		STATUS, 2
			RETURN				; si INDEX < PWD_LENGTH, sigo recibiendo en buffer contraseña
		BCF		INTCON, 3		; si se llenó el buffer contraseña, limpio índice y valido contraseña
		CLRF		RAM_PWD_INDEX
		MOVLW		EEPRM_RD_TO_CR
		CALL		eeprm_init_rd
		MOVLW		READ_TO_CO_RD
		MOVWF		STATE			; paso a transición entre CLOSED y READ
		MOVLW		CO_RD
		MOVWF		NXT_STATE		; aviso que el siguiente estado será READ
		CALL		return_lcd
		RETURN

st_cr:		SLEEP
		NOP
		BTFSS		FLAGS, NEW_KEY
			RETURN
		BCF		FLAGS, NEW_KEY
		BCF		INTCON, 3
		MOVLW		'#'
		XORWF		KEY_ASCII, W
		BTFSS		STATUS, 2
			GOTO		($+9)&0x7FF
		MOVLW		EEPRM_CR_TO_RD
		CALL		eeprm_init_rd
		MOVLW		CO_RD_TO_READ
		MOVWF		STATE
		MOVLW		READ
		MOVWF		NXT_STATE
		CALL		clear_lcd
		RETURN
		MOVLW		'*'
		XORWF		KEY_ASCII, W
		BTFSS		STATUS, 2
			GOTO		($+40)&0x7FF
		MOVLW		EEPRM_PWD
		CALL		eeprm_init_rd		; inicializo EEPROM con la dirección de la contraseña
		CALL		eeprm_read_it		; (*) leo dirección actual, loop de lectura de EEPROM
		IORLW		0
		BTFSS		STATUS, 2		; pregunto si llegué al final de la contraseña (se detecta si se leyó 0xFF) ANTES de haber llegado al valor máximo de índice (condición de error)
			GOTO		($+24)&0x7FF		; si llegué al fin de la contraseña paso a comparar con buffer (+)
		MOVLW		RAM_PWD
		ADDWF		RAM_PWD_INDEX, W
		MOVWF		FSR			; apunto a posición actual de buffer contraseña
		MOVF		INDF, W			; leo su contenido
		BSF		STATUS, 6
		XORWF		EEDATA, W		; pregunto si vale lo mismo que la posición
		BCF		STATUS, 6
		BTFSS		STATUS, 2		; pregunto si vale lo mismo el buffer contraseña que la contraseña en la posición actual
			GOTO		($+15)&0x7FF		; si no valen lo mismo, falló validación de contraseña (+)
		INCF		RAM_PWD_INDEX, F	; si valen lo mismo, incremento índice
		MOVF		RAM_PWD_INDEX, W
		XORLW		PWD_LENGHT		; si el índice llegó a su valor máximo, la contraseña leída es válida y abro la cerradura
		BTFSS		STATUS, 2
			GOTO		($-17)&0x7FF		; si índice no llegó a su valor máximo, loopeo lectura y validación (*)
		CLRF		RAM_PWD_INDEX		; la contraseña leída fue válida, limpio el índice
		MOVLW		EEPRM_CR_TO_SU
		CALL		eeprm_init_rd		; inicializo EEPROM
		MOVLW		CO_RD_TO_SUCC
		MOVWF		STATE			; paso a transición entre READ y SUCC
		MOVLW		SUCC
		MOVWF		NXT_STATE		; se transiciona a SUCC
		CALL		clear_lcd		; limpio LCD
		RETURN
		CLRF		RAM_PWD_INDEX		; (+) la contraseña no fue válida o hubo un error
		MOVLW		EEPRM_CR_TO_FL
		CALL		eeprm_init_rd		; inicializo EEPROM
		MOVLW		CO_RD_TO_FAIL
		MOVWF		STATE			; paso a transición entre READ y FAIL
		MOVLW		FAIL
		MOVWF		NXT_STATE		; se transiciona a FAIL
		BCF		INTCON, 3		; dejo de atender al teclado hasta que se imprima mensaje
		CALL		clear_lcd		; limpio LCD
		RETURN
		MOVF		PORTB, F
		BCF		INTCON, 0
		BSF		INTCON, 3
		RETURN

st_fl:		; la contraseña que se leyó no fue válida, se vuelve a CLOSED pero antes se escribe en el LCD que
		; se equivocó de contraseña, y se espera a que presione una tecla para confirmar que leyó el mensaje
		SLEEP
		NOP
		BTFSS		FLAGS, NEW_KEY		; recibí nueva tecla con RBINT?
			RETURN
		BCF		FLAGS, NEW_KEY		; limpio flag
		BCF		INTCON, 3		; como paso a una transición, deshabilito el teclado hasta que se imprima mensaje
		MOVLW		EEPRM_FL_TO_CL
		CALL		eeprm_init_rd		; inicializo EEPROM
		MOVLW		FAIL_TO_CLOSED
		MOVWF		STATE			; paso a transición entre FAIL y CLOSED
		MOVLW		CLOSED
		MOVWF		NXT_STATE		; aviso que el siguiente estado será CLOSED
		CALL		clear_lcd		; limpio LCD para imprimir mensaje nuevo
		RETURN

st_su:		; la contraseña que se leyó fue válida, se pasa a OPEN, se escribe en el LCD que la contraseña fue
		; correcta y se espera a que se presione una tecla para confirmar que se leyó el mensaje. Se abre la
		; cerradura una vez que el usuario presionó una tecla
		SLEEP
		NOP
		BTFSS		FLAGS, NEW_KEY		; recibí nueva tecla con RBINT?
			RETURN
		BCF		FLAGS, NEW_KEY		; limpio flag
		BCF		INTCON, 3		; como paso a una transición, deshabilito el teclado hasta que se imprima mensaje
		MOVLW		EEPRM_SU_TO_OP
		CALL		eeprm_init_rd		; inicializo EEPROM
		MOVLW		SUCC_TO_OPEN
		MOVWF		STATE			; paso a transición entre SUCC y OPEN
		MOVLW		OPEN
		MOVWF		NXT_STATE		; aviso que el siguiente estado será OPEN
		CALL		clear_lcd		; limpio LCD para imprimir mensaje nuevo
		BSF		PORTD, 7		; abro cerradura
		RETURN

st_op:		SLEEP
		NOP
		BTFSS		FLAGS, NEW_KEY
			RETURN
		BCF		FLAGS, NEW_KEY
		BCF		INTCON, 3
		MOVLW		'#'
		XORWF		KEY_ASCII, W
		BTFSS		STATUS, 2
			GOTO		($+9)&0x7FF
		MOVLW		EEPRM_OP_TO_CH
		CALL		eeprm_init_rd
		MOVLW		OPEN_TO_CHANGE
		MOVWF		STATE
		MOVLW		CHANGE
		MOVWF		NXT_STATE
		CALL		clear_lcd
		RETURN
		MOVLW		'*'
		XORWF		KEY_ASCII, W
		BTFSS		STATUS, 2
			GOTO		($+10)&0x7FF
		MOVLW		EEPRM_OP_TO_CL
		CALL		eeprm_init_rd
		MOVLW		OPEN_TO_CLOSE
		MOVWF		STATE
		MOVLW		CLOSED
		MOVWF		NXT_STATE
		CALL		clear_lcd
		BCF		PORTD, 7		; cierro cerradura
		RETURN
		MOVF		PORTB, F
		BCF		INTCON, 0
		BSF		INTCON, 3
		RETURN

st_ch:		SLEEP
		NOP
		BTFSS		FLAGS, NEW_KEY		; recibí nueva tecla con RBINT?
			RETURN
		BCF		FLAGS, NEW_KEY		; limpio flag
		BCF		INTCON, 3
		MOVLW		RAM_PWD
		ADDWF		RAM_PWD_INDEX, W
		MOVWF		FSR			; apunto a RAM_PWD + INDEX con FSR
		MOVF		KEY_ASCII, W
		MOVWF		INDF			; sobreescribo esa dirección con la tecla recibida
		MOVWF		LCD_DATA		; imprimo tecla recibida en el LCD
		CALL		wait_lcd_ram
		CALL		send_lcd_ram
		INCF		RAM_PWD_INDEX, F	; incremento el índice para atacar la siguiente posición
		MOVF		RAM_PWD_INDEX, W
		XORLW		PWD_LENGHT		; pregunto si el índice llegó a su valor máximo + 1
		MOVF		PORTB, F
		BCF		INTCON, 0
		BSF		INTCON, 3
		BTFSS		STATUS, 2
			RETURN				; si INDEX < PWD_LENGTH, sigo recibiendo en buffer contraseña
		BCF		INTCON, 3		; si se llenó el buffer contraseña, limpio índice y valido contraseña
		CLRF		RAM_PWD_INDEX
		MOVLW		EEPRM_CH_TO_CC
		CALL		eeprm_init_rd
		MOVLW		CHANGE_TO_CO_CH
		MOVWF		STATE			; paso a transición entre CLOSED y READ
		MOVLW		CO_CH
		MOVWF		NXT_STATE		; aviso que el siguiente estado será READ
		CALL		return_lcd
		RETURN

st_cc:		SLEEP
		NOP
		BTFSS		FLAGS, NEW_KEY
			RETURN
		BCF		FLAGS, NEW_KEY
		BCF		INTCON, 3
		MOVLW		'#'
		XORWF		KEY_ASCII, W
		BTFSS		STATUS, 2
			GOTO		($+9)&0x7FF
		MOVLW		EEPRM_CC_TO_CH
		CALL		eeprm_init_rd
		MOVLW		CO_CH_TO_CHANGE
		MOVWF		STATE
		MOVLW		CHANGE
		MOVWF		NXT_STATE
		CALL		clear_lcd
		RETURN
		MOVLW		'*'
		XORWF		KEY_ASCII, W
		BTFSS		STATUS, 2
			RETURN
		BCF		INTCON, 7		; deshabilito interrupciones para escribir EEPROM
		MOVLW		EEPRM_PWD
		CALL		eeprm_init_wr
		MOVLW		RAM_PWD
		ADDWF		RAM_PWD_INDEX, W
		MOVWF		FSR
		MOVF		INDF, W
		BSF		STATUS, 6
		MOVWF		EEDATA
		BCF		STATUS, 6
		CALL		eeprm_write_it
		IORLW		0
		BTFSS		STATUS, 2
			GOTO		($-12)&0x7FF
		INCF		RAM_PWD_INDEX, F
		MOVF		RAM_PWD_INDEX, W
		XORLW		PWD_LENGHT
		BTFSS		STATUS, 2
			GOTO		($-15)&0x7FF
		CLRF		RAM_PWD_INDEX
		BSF		INTCON, 7
		MOVLW		EEPRM_CC_TO_NW
		CALL		eeprm_init_rd
		MOVLW		CO_CH_TO_NEW
		MOVWF		STATE
		MOVLW		NEW
		MOVWF		NXT_STATE
		CALL		clear_lcd
		RETURN

st_nw:		SLEEP
		NOP
		BTFSS		FLAGS, NEW_KEY
			RETURN
		BCF		FLAGS, NEW_KEY
		BCF		INTCON, 3
		MOVLW		EEPRM_NW_TO_OP
		CALL		eeprm_init_rd
		MOVLW		NEW_TO_OPEN
		MOVWF		STATE
		MOVLW		OPEN
		MOVWF		NXT_STATE
		CALL		clear_lcd
		RETURN

; Rutinas de EEPROM

eeprm_init_rd:	; inicializo la dirección de EEPROM con una dirección guardada en W para poder
		; llamar a eeprm_read_it
		BSF		STATUS, 6
		MOVWF		EEADR
		BSF		STATUS, 5
		BCF		EECON1, 2
		BCF		STATUS, 5
		BCF		STATUS, 6
		RETURN

eeprm_read_it:	; código para leer EEPROM
		BSF		STATUS, 6
		BSF		STATUS, 5
		BSF		EECON1, 0		; activo lectura de EEPROM en EEADR
		BCF		STATUS, 5
		MOVF		EEDATA, W
		INCF		EEADR, F
		BCF		STATUS, 6
		XORLW		0xFF
		BTFSC		STATUS, 2
			RETLW		1
		RETLW		0

eeprm_init_wr:	; inicializo la dirección de EEPROM con una dirección guardada en W y 
		; configuro bits de escritura para poder llamar a eeprm_write_it
		BSF		STATUS, 6
		MOVWF		EEADR
		BSF		STATUS, 5
		BSF		EECON1, 2
		BCF		STATUS, 5
		BCF		STATUS, 6
		RETURN

eeprm_write_it:	; código para sobreescribir EEPROM
		BSF		STATUS, 6
		BSF		STATUS, 5
		MOVLW		0x55			; instrucciones de manual
		MOVWF		EECON2			; instrucciones de manual
		MOVLW		0xAA			; instrucciones de manual
		MOVWF		EECON2			; instrucciones de manual
		BSF		EECON1, 1		; activo escritura de EEPROM en EEADR
		BTFSC		EECON1, 1
			GOTO		($-1)&0x7FF
		MOVLW		1
		BTFSC		EECON1, 3
			CLRW
		BCF		STATUS, 5
		INCF		EEADR, F
		BCF		STATUS, 6
		IORLW		0
		BTFSC		STATUS, 2
			RETLW		1
		RETLW		0

; Look-up tables

		psect	lut_vec, global, abs, ovrld, delta=2, class=CODE
		ORG	0x300

TBL_OFFSET	equ		0x50
CANT_COLS	equ		3

filcol_table:	; tabla auxiliar para teclado matricial
		MOVWF		TBL_OFFSET
		MOVLW		high(filcol_table)
		MOVWF		PCLATH
		MOVF		TBL_OFFSET, W
		ADDWF		PCL, F
		RETLW		16
		RETLW		0 * CANT_COLS
		RETLW		1 * CANT_COLS
		RETLW		16
		RETLW		2 * CANT_COLS
		RETLW		16
		RETLW		16
		RETLW		16
		RETLW		3 * CANT_COLS
		RETLW		16
		RETLW		16
		RETLW		2
		RETLW		16
		RETLW		1
		RETLW		0
		RETLW		16

kycod_to_ascii:	; tabla de conversión entre índice de tecla y su valor ASCII correspondiente
		MOVLW		high(kycod_to_ascii)
		MOVWF		PCLATH
		MOVF		KEYCODE, W
		ADDWF		PCL, F
		RETLW		'1'
		RETLW		'2'
		RETLW		'3'
		RETLW		'4'
		RETLW		'5'
		RETLW		'6'
		RETLW		'7'
		RETLW		'8'
		RETLW		'9'
		RETLW		'#'
		RETLW		'0'
		RETLW		'*'

; Escritura de EEPROM

		psect	eeprom_vec, global, delta=2, class=EEDATA
		ORG	0x00
		; contraseña arranca en 0x00
EEPRM_PWD:	DB		'1','2','3','4','5','6', 0xFF

		; mensaje de X_TO_CLOSED
EEPRM_RS_TO_CL:
EEPRM_FL_TO_CL:
EEPRM_OP_TO_CL:	DB		'C', 'e', 'r', 'r', 'a', 'd', 'o', ',', 0x00, 'e', 's', 'p', 'e', 'r', 'a', 'n', 'd', 'o', ' ', 't', 'e', 'c', 'l', 'a', 0xFF

		; mensaje de CLOSED_TO_READ y OPEN_TO_CHANGE
EEPRM_CL_TO_RD:
EEPRM_CR_TO_RD:
EEPRM_OP_TO_CH:
EEPRM_CC_TO_CH:	DB		'I', 'n', 'g', 'r', 'e', 's', 'e', ' ', 'c', 'o', 'n', 't', 'r', 'a', ':', 0x00, ' ', ' ', ' ', ' ', ' ', 0xFF

		; mensaje de FAIL_TO_CLOSE
EEPRM_CR_TO_FL:	DB		'C', 'o', 'n', 't', 'r', 'a', ' ', 'f', 'a', 'l', 'l', 'i', 'd', 'a', 0x00, 'e', 's', 'p', 'e', 'r', 'a', 'n', 'd', 'o', ' ', 't', 'e', 'c', 'l', 'a', 0xFF

		; mensaje de READ_TO_SUCC
EEPRM_CR_TO_SU:	DB		'C', 'o', 'n', 't', 'r', 'a', ' ', 'c', 'o', 'r', 'r', 'e', 'c', 't', 'a', 0x00, 'e', 's', 'p', 'e', 'r', 'a', 'n', 'd', 'o', ' ', 't', 'e', 'c', 'l', 'a', 0xFF

		; mensaje de SUCC_TO_OPEN y NEW_TO_OPEN
EEPRM_SU_TO_OP:
EEPRM_NW_TO_OP:	DB		'A', 'b', 'i', 'e', 'r', 't', 'o', ' ', '*', '.', 'C', 'i', 'e', 'r', 'r', 'a', 0x00, '#', '.', 'C', 'a', 'm', 'b', 'i', 'a', 'r', 0xFF

		; mensaje de CHANGE_TO_NEW
EEPRM_CC_TO_NW:	DB		'C', 'o', 'n', 't', 'r', 'a', ' ', 'n', 'u', 'e', 'v', 'a', 0x00, 'e', 's', 'p', 'e', 'r', 'a', 'n', 'd', 'o', ' ', 't', 'e', 'c', 'l', 'a', 0xFF

		; mensaje de confirmar contraseña
EEPRM_RD_TO_CR:
EEPRM_CH_TO_CC:	DB		'*', '.', 'O', 'k', ' ', '#', '.', 'R', 'e', 'i', 'n', 't', 'e', 'n', 't', 'a', 0xFF

		END	main

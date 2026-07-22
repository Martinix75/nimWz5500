import std/[strutils, os]
import futhark
import picostdlib
import picostdlib/hardware/[spi, gpio]

proc renameWiznet(name: string, kind: SymbolKind, partOf: string, overloading: var bool): string =
  #if kind == nskProc:
    result = "wz_" & name  # es: close → wz_close, socket → wz_socket
  #else:
   # result = name  # tipi e costanti restano invariati


importc:
  renameCallback renameWiznet
  path currentSourcePath.parentDir / "Ethernet"
  #path "Ethernet"
  "wizchip_conf.h"
  "W5500/w5500.h"
  "socket.h"

type
  EthProtocol* = enum #scelta protocollod a usare
    Mode_UDP, Mode_TCP
    
  EthCom* = object #oggetto per semplificare la comunicazione.
    spi: ptr SpiInst #memorizza il blocco SPI.
    baudrate: cuint #memorizza il baudrate in uso
    pinSck, pinMosi, pinMiso, pinCs: Gpio #memorizza i pin da usare per SPI.
    pinRst: GpioOptional #pin di reset hardhare opzionale ver 0.3.0
    protocol: EthProtocol #scegli il protocollod a usare UDP o TCP.
    port: uint16
    socket*: uint8
    rxBuffer*: array[64, uint8] #crea un buffer per memorizzare i dati
    clientIp: array[4, uint8] #buffer x memorizzare ip del Client.
    clientPort: uint16 #memorizza la porta del client.
    mac*: array[6, uint8] = [0xDE'u8, 0xAD, 0xBE, 0xEF, 0xFE, 0x01] #memorizza ll'indirizzo MAC ver 0.3.4
    ip*: array[4, uint8] = [192'u8, 168, 0, 1] #memorizza l'inrizzo IP ver 0.3.4 .
    sn*: array[4, uint8] = [255'u8, 255, 255, 0]#memorizza la maschera di rete ver 0.3.4 .
    gw*: array[4, uint8] = [192'u8, 168, 0, 1] #memorizza il gateway ver 0.3.4 .

const
  W5500Version*   = "0.3.4" # modifica oggetto.
  SOCK_STREAM*    = wz_Sn_MR_TCP #alias TCP per compattibilita BSD socket.
  SOCK_DGRAM*     = wz_Sn_MR_UDP #alias UDP per compattibilità BSD socket.
  MAX_SOCK_NUM*   = 8.uint8 #numero massimo di socket contemporanei.
  W5500_VERSIONR* = 0x04.uint8 #valore atteso dal registro versione interno.

var
  comSpi: ptr SpiInst # porta spi attiva impostata da w5500init.
  comPinCs: Gpio # pin GPIO chip select, impostatto da w5500init.


# ----------- Prototipi di Procedura ----------
proc w5500SpiReadByte(): uint8 {.cdecl.} #legge un singolo byte da SPI.
proc w5500SpiWriteByte(b: uint8) {.cdecl.} #scrive un singolo byte.
proc w5500SpiReadBurst(buf: ptr uint8; len: uint16) {.cdecl.} #legge "len" byte da SPI in modalita brust.
proc w5500SpiWriteBurst(buf: ptr uint8; len: uint16) {.cdecl.} #scrive "len" byte su SPI in modalità brust.
proc w5500CsSelect() {.cdecl.} #abbassa il pin CS (attivo basso) per selezionare il dispositivo w5500 su SPI.
proc w5500CsDeselect() {.cdecl.} #Alza il pin CS per deselezionare il w5500 dal SPI.
#proc w5500ReadVersionRaw*(spi: ptr SpiInst; pinCs: Gpio): uint8 #legge il registo versione interno da spi (senza libreria wznet).
proc w5500ReadVersionRaw*(eth: EthCom): uint8
proc w5500HardReset*(eth: EthCom) #soft reser per w5500 senza pin fidico.
proc w5500Init*(spi: ptr SpiInst; baudrate: cuint; pinSck, pinMosi, pinMiso, pinCs: Gpio; 
                protocol: EthProtocol; port: uint16; socket: uint8=0; pinRst: GpioOptional = GpioUnused): EthCom #inizializza porta SPI e chip w5500.
proc sendDataEth*(eth: var EthCom; txBuffer: string; socket: uint8 = 0): int32 #proc nim semplificata per pedire dati ver 0.2.0
proc recvDataEth*(eth: var EthCom; socket: uint8 = 0): int32 #procedura semplificata Nim per ricevere dati ver 0.2.0.
proc getSn_SR*(sn: uint8): uint8
proc setSocket*(eth: var EthCom) #setta il sochet da usare UDP o TCP.
proc socketStatus*(eth: EthCom): uint8 #alias NIM per decretare la connessione corrente del socket ver 0.2.0.
proc rxBytesAvailable*(eth: EthCom): uint16 #alias NIM per il ritorno dei byte disponibili nel buffer RX del soket ver 0.2.0
proc w5500Reset*(eth: var EthCom) #reset software per resettare manualmente il w5500 ver 0.3.0
proc dataToString*(eth: EthCom; data: int32): string  #utilità per la conversione dati grezzi in stringhe ver 0.3.2 .
proc w5500SetNetInfo*(eth: var EthCom)
# ----------- Fine Prototipi di Procedura ----------

# ---------- Inizio Procedure Reali ----------
proc w5500SpiReadByte(): uint8 =
  ## Legge un singolo byte dalla SPI.
  ## Trasmette 0xFF come dummy byte (richiesto dal protocollo SPI full-duplex).
  var b: uint8 = 0
  discard comSpi.readBlocking(0xFF.uint8, b.addr, 1.csize_t) #Legge su SPI.
  result = b

proc w5500SpiWriteByte(b: uint8) =
  ## Scrive un singolo byte sulla SPI.
  var tx = b
  discard comSpi.writeBlocking(tx.addr, 1.csize_t)

proc w5500SpiReadBurst(buf: ptr uint8; len: uint16) =
  ## Legge `len` byte dalla SPI in modalità burst.
  ## Usato dalla libreria per letture di blocchi dati (più efficiente dei singoli byte).
  discard comSpi.readBlocking(0xFF.uint8, buf, len.csize_t)

proc w5500SpiWriteBurst(buf: ptr uint8; len: uint16) =
  ## Scrive `len` byte sulla SPI in modalità burst.
  discard comSpi.writeBlocking(buf, len.csize_t)

proc w5500CsSelect() =
  ## Abbassa il pin CS (logica attiva bassa) per selezionare il W5500 sul bus SPI.
  comPinCs.put(Low)

proc w5500CsDeselect() =
  ## Alza il pin CS per deselezionare il W5500 e liberare il bus SPI.
  comPinCs.put(High)

proc w5500ReadVersionRaw*(eth: EthCom): uint8 =
  ## Legge il registro versione W5500 direttamente via SPI (senza libreria WIZnet).
  ## Risposta attesa: 0x04
  ## Se restituisce 0x00 o altro: verificare cablaggio e alimentazione (3.3V).
  eth.pinCs.put(Low)                                        # seleziona chip
  sleepMs(1)
  var tx = [0x00.uint8, 0x39, 0x00]                       # indirizzo + control byte
  discard eth.spi.writeBlocking(tx[0].addr, 3.csize_t)     # invia header
  var rx: uint8 = 0
  discard eth.spi.readBlocking(0xFF.uint8, rx.addr, 1.csize_t) # leggi risposta
  sleepMs(1)
  eth.pinCs.put(High)                                       # deseleziona chip
  result = rx

#[proc w5500ReadVersionRaw*(spi: ptr SpiInst; pinCs: Gpio): uint8 =
  ## Legge il registro versione W5500 direttamente via SPI (senza libreria WIZnet).
  ## Risposta attesa: 0x04
  ## Se restituisce 0x00 o altro: verificare cablaggio e alimentazione (3.3V).
  pinCs.put(Low)                                        # seleziona chip
  sleepMs(1)
  var tx = [0x00.uint8, 0x39, 0x00]                       # indirizzo + control byte
  discard spi.writeBlocking(tx[0].addr, 3.csize_t)     # invia header
  var rx: uint8 = 0
  discard spi.readBlocking(0xFF.uint8, rx.addr, 1.csize_t) # leggi risposta
  sleepMs(1)
  pinCs.put(High)                                       # deseleziona chip
  result = rx]#

proc w5500Reset*(eth: var EthCom) =
  ## Esegue un reset hardware del W5500 tramite il pin RST fisico.
  ## Da usare quando il chip si incasina (socket bloccate, nessuna risposta).
  ## Non fa niente se pinRst non è stato specificato in w5500Init.
  if eth.pinRst != GpioUnused:
    let rst = Gpio(cuint(eth.pinRst))
    rst.put(Low)    # chip in reset
    sleepMs(10)
    rst.put(High)   # chip operativo
    sleepMs(200)    # attesa stabilizzazione
    # Dopo il reset il chip va reinizializzato
    var txBufSize: array[8, uint8] = [2.uint8, 2, 2, 2, 2, 2, 2, 2]
    var rxBufSize: array[8, uint8] = [2.uint8, 2, 2, 2, 2, 2, 2, 2]
    discard wz_wizchip_init(txBufSize[0].addr, rxBufSize[0].addr)
    setSocket(eth)  # riapre la socket
  else:
    echo "W5500 reset: pin RST non specificato, niente da fare."
    
proc w5500HardReset*(eth: EthCom) =
  ## Soft reset del W5500 via registro MR (indirizzo 0x0000, bit 7 = RST).
  ## Equivale a un reset hardware senza il pin RST fisico.
  eth.pinCs.put(Low)
  sleepMs(1)
  # Frame: addr_hi=0x00, addr_lo=0x00, control=0x04 (write, common reg, 1-byte), data=0x80
  var tx = [0x00.uint8, 0x00, 0x04, 0x80]
  discard eth.spi.writeBlocking(tx[0].addr, 4.csize_t)
  eth.pinCs.put(High)
  sleepMs(200)  # attesa reset completo (datasheet dice 1ms, mettiamo 200 per sicurezza)

proc w5500Init*(spi: ptr SpiInst; baudrate: cuint; pinSck, pinMosi, pinMiso, pinCs: Gpio; 
                protocol: EthProtocol; port: uint16; socket: uint8=0; pinRst: GpioOptional = GpioUnused): EthCom =
  comSpi   = spi
  comPinCs = pinCs
  if pinRst != GpioUnused: #se stai usando il reset....
    let rst = Gpio(cuint(pinRst))
    rst.init()
    rst.setDir(Out)
    rst.put(Low)    # chip in reset
    sleepMs(10)
    rst.put(High)   # chip libero di partire
    sleepMs(200)    # attesa stabilizzazione (datasheet: min 1ms)
  discard spi.init(baudrate)
  # Configura SCK, MOSI, MISO come pin con funzione hardware SPI
  pinSck.setFunction(Spi)
  pinMosi.setFunction(Spi)
  pinMiso.setFunction(Spi)
  # Il CS viene gestito manualmente (non come funzione SPI hardware)
  # per avere controllo preciso del timing richiesto dal protocollo W5500
  pinCs.init()
  pinCs.setDir(Out)
  pinCs.put(High)   # CS alto = chip deselezionato (stato di riposo del bus)
  # Breve attesa per stabilizzazione alimentazione e linee SPI
  sleepMs(100)
  #w5500HardReset(spi, pinCs) blocca la comunicazioe non usare qui!!!
  # Registra i callback SPI nella struttura interna della libreria WIZnet.
  # Da questo momento tutta la comunicazione col chip passerà da queste funzioni.
  wz_reg_wizchip_cs_cbfunc(w5500CsSelect, w5500CsDeselect)
  wz_reg_wizchip_spi_cbfunc(w5500SpiReadByte, w5500SpiWriteByte)
  wz_reg_wizchip_spiburst_cbfunc(w5500SpiReadBurst, w5500SpiWriteBurst)
  # Inizializza il chip e alloca i buffer interni.
  # 2KB per socket × 8 socket = 16KB TX + 16KB RX (usa tutta la RAM interna W5500)
  var txBufSize: array[8, uint8] = [2.uint8, 2, 2, 2, 2, 2, 2, 2]
  var rxBufSize: array[8, uint8] = [2.uint8, 2, 2, 2, 2, 2, 2, 2]
  discard wz_wizchip_init(txBufSize[0].addr, rxBufSize[0].addr)
  result = EthCom(spi: spi, baudrate: baudrate, pinSck: pinSck, pinMosi: pinMosi, pinMiso: pinMiso, pinCs: pinCs,
                  protocol: protocol, port: port, socket: socket, pinRst: pinRst)
  setSocket(result)

proc setSocket*(eth: var EthCom) =
  case eth.protocol:
    of Mode_UDP: 
      discard wz_socket_proc(eth.socket, wz_Sn_MR_UDP, eth.port, 0)
    of Mode_TCP:
      discard wz_socket_proc(eth.socket, wz_Sn_MR_TCP, eth.port, 0)
      discard wz_listen(eth.socket)
      
proc w5500SetNetInfo*(eth: var EthCom) =
  ## Applica la configurazione di rete memorizzata nell'oggetto EthCom.
  ## Imposta eth.mac, eth.ip, eth.sn, eth.gw prima di chiamarla.
  var info: wz_wiz_NetInfo
  info.wz_mac  = eth.mac
  info.wz_ip   = eth.ip
  info.wz_sn   = eth.sn
  info.wz_gw   = eth.gw
  info.wz_dhcp = wz_NETINFO_STATIC
  wz_wizchip_setnetinfo(info.addr)
  
  
proc sendDataEth*(eth: var EthCom; txBuffer: string; socket: uint8 = 0): int32 =
  case eth.protocol:
    of Mode_UDP:
      result = wz_sendto_W5x00(socket,                             #socket da cui tramettere.
                            cast[ptr uint8](txBuffer[0].addr),  #dati da inviare.
                            txBuffer.len().uint16,              #lunghezza dati da inviare.
                            eth.clientIp[0].addr,               #IP di destianzione dati. 
                            eth.clientPort)                     #porta di destinazione dei dati. 
    of Mode_TCP:
        result = wz_send(socket, cast[ptr uint8](txBuffer[0].addr),
                      txBuffer.len().uint16)

proc recvDataEth*(eth: var EthCom; socket: uint8 = 0): int32 =
  case eth.protocol:
    of Mode_UDP:
      result = wz_recvfrom_W5x00(socket,                           #socket da cui leggere.
                              eth.rxBuffer[0].addr,             #buffer di destinazione.
                              eth.rxBuffer.len().uint16,        #dimensione massima del buffer.
                              eth.clientIp[0].addr,             #memoriza IP mittente.
                              eth.clientPort.addr)              #memorizza porta mittente.
    of Mode_TCP:
      result = wz_recv(socket, eth.rxBuffer[0].addr,
                    eth.rxBuffer.len().uint16)
      
proc socketStatus*(eth: EthCom): uint8 = #è un alias NIM!!!!!!
  ## Ritorna lo stato corrente della socket dell'oggetto EthCom.
  ## Valori: wz_SOCK_CLOSED, wz_SOCK_LISTEN, wz_SOCK_ESTABLISHED, wz_SOCK_CLOSE_WAIT...
  ## wz_SOCK_CLOSED       Socket chiusa o non inizializzata
  ## wz_SOCK_LISTEN       In ascolto di connessioni (TCP)
  ## wz_SOCK_ESTABLISHED  Connessione attiva — dati trasferibili
  ## wz_SOCK_CLOSE_WAIT   Client ha chiuso, in attesa di cleanup
  ## wz_SOCK_UDP          Socket UDP aperta e operativa
  result = getSn_SR(eth.socket)
                        
proc getSn_SR*(sn: uint8): uint8 =
  ## Legge lo stato della socket sn direttamente via SPI.
  ## Block select W5500: socket n = (sn * 4 + 1) << 3
  let bsb = uint8((sn.int * 4 + 1) shl 3)  # block select byte
  comPinCs.put(Low)
  var tx = [0x00'u8, 0x03, bsb]  # addr 0x0003 = Sn_SR
  discard comSpi.writeBlocking(tx[0].addr, 3.csize_t)
  var rx: uint8 = 0
  discard comSpi.readBlocking(0xFF'u8, rx.addr, 1.csize_t)
  comPinCs.put(High)
  result = rx

proc rxBytesAvailable*(eth: EthCom): uint16 =
  ## Ritorna il numero di byte disponibili nel buffer RX della socket.
  ## 0 = niente da leggere. Utile per evitare letture bloccanti.
  result = wz_getSn_RX_RSR(eth.socket)

proc dataToString*(eth: EthCom; data: int32): string =
  var message = newString(data) #chre uan ustringa da riempire...
  for datax in 0..<data:
    message[datax] = eth.rxBuffer[datax.int].char #converte in char e memoriza il carattere.
  result = message.strip() #pulisce la stringa da sporcizzia.
  
  
  # ---------- Fine Procedure Reali ----------
when isMainModule:
  import std/strformat

  # ===========================================================================
  # Esempio TCP server v0.3.4 — API OOP completa
  # Test da PC: nc -w5 192.168.0.140 5000
  # Comandi: ciao → buongiorno!  |  stato → tutto ok  |  altro → non riconosciuto
  # ===========================================================================

  discard stdioInitAll()
  sleepMs(2000)
  echo fmt"=== W5500 TCP Server ver {W5500Version} ==="

  # Init chip — usa i default dell'oggetto per la rete
  var eth = w5500Init(spi0, 1_000_000.cuint,
                      2.Gpio, 3.Gpio, 4.Gpio, 5.Gpio,
                      Mode_TCP, 5000)

  # Verifica SPI fisica
  let ver = eth.w5500ReadVersionRaw()
  echo "W5500 version: 0x", ver.toHex()
  if ver != W5500_VERSIONR:
    echo "ERRORE SPI! Verificare cablaggio (3.3V). Fermo."
    while true: sleepMs(1000)
  echo "SPI OK."

  # Configura rete — modifica solo i campi che vuoi cambiare
  # eth.mac è già [0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0x01] per default
  # eth.sn  è già [255, 255, 255, 0] per default
  eth.ip = [192'u8, 168, 0, 140]  # cambio IP da default 0.1 a 0.140
  eth.gw = [192'u8, 168, 0, 1]
  eth.w5500SetNetInfo() # applica la configurazione sualo SEMPRE!!
  echo fmt"Rete: {eth.ip[0]}.{eth.ip[1]}.{eth.ip[2]}.{eth.ip[3]}"

  # Loop principale — un client alla volta
  while true:
    echo fmt"In ascolto porta TCP {eth.port}... (nc -w5 192.168.0.140 5000)"
    while eth.socketStatus() != wz_SOCK_ESTABLISHED:
      sleepMs(10)
    echo "Client connesso!"

    # Attendi dati
    var rxLen: int32 = 0
    while rxLen <= 0:
      rxLen = eth.recvDataEth(eth.socket)
      sleepMs(10)

    # Converti e processa comando
    let msg = eth.dataToString(rxLen)
    echo fmt"Ricevuto: {msg}"

    let risposta =
      if   msg == "ciao":  "buongiorno!\n"
      elif msg == "stato": "tutto ok\n"
      elif msg == "ver": fmt"Versione Lib: {W5500Version}"
      else:                "comando non riconosciuto\n"

    discard eth.sendDataEth(risposta, eth.socket)
    echo fmt"Risposto: {risposta.strip()}"

    # Chiudi e riapri per il prossimo client
    discard wz_close(eth.socket)
    sleepMs(100)
    eth.setSocket()

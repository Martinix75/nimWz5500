# w5500.nim — Ethernet Library for RP2040 in Nim

A Nim wrapper for the WIZnet W5500 Ethernet chip on Raspberry Pi Pico (RP2040),
built on top of the official [WIZnet ioLibrary_Driver](https://github.com/Wiznet/ioLibrary_Driver)
using [Futhark](https://github.com/PMunch/futhark) for C bindings.

Supports TCP and UDP with a clean, idiomatic Nim API.

---

## Hardware Requirements

- Raspberry Pi Pico (RP2040)
- WIZnet W5500 module
- Power supply: **3.3V only** (the W5500 is NOT 5V tolerant)

### Default Wiring (SPI1)

| RP2040 GPIO | W5500 Pin | Description        |
|-------------|-----------|--------------------|
| GP10        | SCK       | SPI Clock          |
| GP11        | MOSI      | Data Pico → W5500  |
| GP12        | MISO      | Data W5500 → Pico  |
| GP13        | CS        | Chip Select        |
| GP15        | RST       | Reset (optional)   |
| 3.3V        | VCC       | Power supply       |
| GND         | GND       | Ground             |

> Any SPI-capable GPIO pins can be used — see `w5500Init` parameters.

---

## Installation

### 1. Copy library files into your project

Copy the following into your project's `src/DEPS/w5500/` folder:

```
src/
└── DEPS/
    └── w5500/
        ├── w5500.nim        ← main library file
        └── Ethernet/        ← WIZnet C sources (required)
            ├── wizchip_conf.h / .c
            ├── socket.h / .c
            ├── W5500/
            ├── W6300/
            └── ...
```

### 2. Add to your CMakeLists.txt

Add the following block to your project's `CMakeLists.txt`
(adjust paths if you placed the library elsewhere):

```cmake
# ----- W5500 WIZnet library -----
target_sources(${OUTPUT_NAME} PRIVATE
    src/DEPS/w5500/Ethernet/W5500/w5500.c
    src/DEPS/w5500/Ethernet/wizchip_conf.c
    src/DEPS/w5500/Ethernet/socket.c
)
target_include_directories(${OUTPUT_NAME} PRIVATE
    src/DEPS/w5500/Ethernet
    src/DEPS/w5500/Ethernet/W5500
    src/DEPS/w5500/Ethernet/W6300
)
target_compile_definitions(${OUTPUT_NAME} PRIVATE
    _WIZCHIP_=W5500
)
# --------------------------------
```

### 3. Add to your project's config.nims

Add this switch to avoid symbol redefinition errors with Futhark:

```nim
switch("define", "nodeclguards")
```

### 4. Import in your Nim source

```nim
import DEPS/w5500/w5500
```

---

## API Reference

### Initialization

```nim
proc w5500Init*(spi: ptr SpiInst; baudrate: cuint;
                pinSck, pinMosi, pinMiso, pinCs: Gpio;
                protocol: EthProtocol; port: uint16;
                socket: uint8 = 0;
                pinRst: GpioOptional = GpioUnused): EthCom
```
Initializes the SPI peripheral and the W5500 chip, opens the socket.
Returns an `EthCom` object used for all subsequent operations.

- `spi` — SPI instance: `spi0` or `spi1`
- `baudrate` — SPI clock speed in Hz (e.g. `10_000_000` for 10 MHz)
- `pinSck/pinMosi/pinMiso/pinCs` — GPIO pins for SPI
- `protocol` — `Mode_TCP` or `Mode_UDP`
- `port` — local port number to listen on
- `socket` — W5500 socket number (0..7, default 0)
- `pinRst` — optional hardware reset pin (e.g. `15.GpioOptional`); omit if not connected

---

### Network Configuration

```nim
proc w5500SetNetInfo*(mac: array[6, uint8];
                      ip:  array[4, uint8];
                      sn:  array[4, uint8];
                      gw:  array[4, uint8])
```
Sets static IP configuration (MAC address, IP, subnet mask, gateway).
Must be called after `w5500Init` and before any data transfer.

---

### Data Transfer

```nim
proc sendDataEth*(eth: var EthCom; txBuffer: string; socket: uint8 = 0): int32
```
Sends a string over the network.
- TCP: sends over the established connection
- UDP: sends to the last client that sent data (IP/port stored internally)

```nim
proc recvDataEth*(eth: var EthCom; socket: uint8 = 0): int32
```
Receives data into `eth.rxBuffer`. Returns the number of bytes received (0 if nothing available).
- TCP: reads from the established connection
- UDP: also stores sender IP/port internally for the reply

```nim
proc dataToString*(eth: EthCom; data: int32): string
```
Converts the raw bytes in `eth.rxBuffer` into a clean Nim string.
- `data` — number of bytes to convert (typically the value returned by `recvDataEth`)
- Strips trailing whitespace, newlines and carriage returns automatically
- Simplifies the typical receive-and-parse pattern into a single call

Example:
```nim
let rxLen = recvDataEth(eth, eth.socket)
if rxLen > 0:
  let msg = eth.dataToString(rxLen)  # ready to use — no manual conversion needed
  echo "Received: ", msg
```

---

### Socket Management

```nim
proc setSocket*(eth: var EthCom)
```
Opens the socket and (for TCP) starts listening.
Call this after `close` to accept a new client connection.

```nim
proc socketStatus*(eth: EthCom): uint8
```
Returns the current socket state. Common values:

| Constant           | Meaning                              |
|--------------------|--------------------------------------|
| `SOCK_CLOSED`      | Socket not open                      |
| `SOCK_LISTEN`      | TCP: waiting for incoming connection |
| `SOCK_ESTABLISHED` | TCP: connection active               |
| `SOCK_CLOSE_WAIT`  | TCP: remote side closed connection   |
| `SOCK_UDP`         | UDP: socket open and ready           |

```nim
proc rxBytesAvailable*(eth: EthCom): uint16
```
Returns the number of bytes waiting in the RX buffer. Useful to avoid blocking reads.

---

### Diagnostics & Reset

```nim
proc w5500ReadVersionRaw*(spi: ptr SpiInst; pinCs: Gpio): uint8
```
Reads the W5500 version register directly via SPI, bypassing the WIZnet library.
Expected return value: `0x04`. Use this to verify SPI wiring before full initialization.

```nim
proc w5500Reset*(eth: var EthCom)
```
Performs a hardware reset via the RST pin (if connected).
Automatically reinitializes the chip and reopens the socket.
Does nothing if `pinRst` was not specified in `w5500Init`.

---

### Constants

| Constant         | Value  | Description                        |
|------------------|--------|------------------------------------|
| `W5500Version`   | string | Library version                    |
| `W5500_VERSIONR` | `0x04` | Expected chip version register     |
| `MAX_SOCK_NUM`   | `8`    | Maximum simultaneous sockets       |
| `SOCK_STREAM`    | —      | BSD alias for TCP (`Sn_MR_TCP`)    |
| `SOCK_DGRAM`     | —      | BSD alias for UDP (`Sn_MR_UDP`)    |

---

## Usage Examples

### TCP Server

Listens for one client at a time, responds to a command, then closes the connection.
Test from PC: `nc 192.168.0.130 5000`

```nim
import DEPS/w5500/w5500
import picostdlib

# Initialize W5500 in TCP mode on port 5000
var eth = w5500Init(spi1, 10_000_000.cuint,
                    10.Gpio, 11.Gpio, 12.Gpio, 13.Gpio,
                    Mode_TCP, 5000)

# Verify SPI communication
let ver = w5500ReadVersionRaw(spi1, 13.Gpio)
if ver != W5500_VERSIONR:
  echo "SPI error! Check wiring."
  while true: sleepMs(1000)

# Set static IP configuration
w5500SetNetInfo(
  mac = [0xDE'u8, 0xAD, 0xBE, 0xEF, 0xFE, 0x01],
  ip  = [192'u8, 168, 0, 130],
  sn  = [255'u8, 255, 255, 0],
  gw  = [192'u8, 168, 0, 1]
)

while true:
  # Wait for client connection
  while eth.socketStatus() != SOCK_ESTABLISHED:
    sleepMs(10)

  # Wait for incoming data
  var rxLen: int32 = 0
  while rxLen <= 0:
    rxLen = recvDataEth(eth, eth.socket)
    sleepMs(10)

  # Convert buffer to string (dataToString handles it in one call)
  let msg = eth.dataToString(rxLen)

  # Select response
  let response =
    if   msg == "hello": "hi there!\n"
    elif msg == "status": "all good\n"
    else: "unknown command\n"

  # Send response and close connection
  discard sendDataEth(eth, response, eth.socket)
  sleepMs(100)
  discard wz_close(eth.socket)
  sleepMs(100)
  setSocket(eth)  # reopen for next client
```

---

### UDP Server

Responds to UDP datagrams. No connection management needed.
Test from PC: `echo "hello" | nc -u -w1 192.168.0.130 5000`

```nim
import DEPS/w5500/w5500
import picostdlib

var eth = w5500Init(spi1, 10_000_000.cuint,
                    10.Gpio, 11.Gpio, 12.Gpio, 13.Gpio,
                    Mode_UDP, 5000)

w5500SetNetInfo(
  mac = [0xDE'u8, 0xAD, 0xBE, 0xEF, 0xFE, 0x01],
  ip  = [192'u8, 168, 0, 130],
  sn  = [255'u8, 255, 255, 0],
  gw  = [192'u8, 168, 0, 1]
)

while true:
  let rxLen = recvDataEth(eth, eth.socket)
  if rxLen > 0:
    let msg = eth.dataToString(rxLen)

    let response =
      if   msg == "hello": "hi there!\n"
      elif msg == "status": "all good\n"
      else: "unknown command\n"

    discard sendDataEth(eth, response, eth.socket)
  sleepMs(10)
```

---

## Notes

- The W5500 handles ARP and ICMP (ping) autonomously in hardware — no code needed.
- Always power the W5500 at **3.3V**. 5V will damage the chip.
- Handle the chip with care — it is sensitive to electrostatic discharge (ESD).
- For TCP, always call `wz_close` + `setSocket` after each client to accept the next one.
- For UDP, `nc -u -w1` (with timeout) is recommended to avoid netcat hanging after the reply.

---

## License

MIT — see LICENSE file.

## Author

Martinix / CNR  
Version 0.3.1

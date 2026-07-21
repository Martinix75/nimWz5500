before build:
  const cmakeFile = "CMakeLists.txt"
  const marker    = "src/Ethernet/W5500/w5500.c"
  const wiznetBlock = """
# ----- W5500 WIZnet library -----
target_sources(${OUTPUT_NAME} PRIVATE
    src/Ethernet/W5500/w5500.c
    src/Ethernet/wizchip_conf.c
    src/Ethernet/socket.c
)
target_include_directories(${OUTPUT_NAME} PRIVATE
    src/Ethernet
    src/Ethernet/W5500
    src/Ethernet/W6300
)
target_compile_definitions(${OUTPUT_NAME} PRIVATE
    _WIZCHIP_=W5500
)
"""
  let content = readFile(cmakeFile)
  if marker notin content:
    writeFile(cmakeFile, content & wiznetBlock)
    echo "CMakeLists.txt: aggiunte righe W5500."
  else:
    echo "CMakeLists.txt: righe W5500 già presenti."

1 copia nel tuo file CMakelist.txt:
#---------- aggunto a mano ----------------
target_sources(${OUTPUT_NAME} PRIVATE
    src/DEPS/w5500/Ethernet/W5500/w5500.c
    src/DEPS/w5500/Ethernet/wizchip_conf.c
    src/DEPS/w5500/Ethernet/socket.c
)
# ----- inserii a mano x la copilazione -----------------------

target_include_directories(${OUTPUT_NAME} PRIVATE
    src/DEPS/w5500/Ethernet
    src/DEPS/w5500/Ethernet/W5500
    src/DEPS/w5500/Ethernet/W6300
)


target_compile_definitions(${OUTPUT_NAME} PRIVATE
    _WIZCHIP_=W5500
)
ovviamente occhio che i percorsi siano corretti!!!!!

2 sarebbe meglio aggiungere al file .nims del tuo progetto lo switch (per futhark):
  switch("define", "nodeclguards")

# KLayout script: erase Metal2 and Metal3 fill shapes only.
# Run with: klayout -zz -r erase_m2m3_fill.py /path/to/file.gds
import pya

layout = pya.CellView.active().layout()
layout.clear_layer(layout.layer(10, 22))  # Metal2 fill (datatype 22)
layout.clear_layer(layout.layer(30, 22))  # Metal3 fill (datatype 22)
layout.write(pya.CellView.active().filename())
print("Erased Metal2/Metal3 fill layers.")

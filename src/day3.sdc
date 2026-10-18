// Timing constraints for BigPig-Bro (GW2A-18)
// System clock: 27MHz crystal -> period = 1000/27 = 37.037ns
create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]
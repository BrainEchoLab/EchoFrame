# core/verasonics/

Bridges the Verasonics Vantage world and EchoFrame's. Only needed on the live
acquisition path; the simulation examples build their specs directly.

- **`vsx_to_ef_structs.m`** — reads the Verasonics globals (`Resource`, `Trans`, `TX`,
  `Receive`) and returns `ProbeSpec` / `TransmitSpec` / `ReceiveSpec`. Element
  geometry, pitch, centre frequency, steering angles, transmit delays and speed of
  sound all come across here.
- **`get_system_parameters.m`** — the other direction: derives Verasonics `Resource`
  and receive settings from the chosen acquisition parameters and sampling mode.
- **`calculate_transmit_apodization.m`** / **`calculate_receive_apodization.m`** —
  Tukey-windowed apodization vectors over the centred active aperture, for
  `TX(*).Apod` and `Receive(*).Apod`. The aperture percentage is rounded to an even
  element count so it stays centred.

> Both apodization helpers force weights of 0.2 and below to zero, working around a
> Verasonics bug with very small apodization values.

Runnable acquisition setups live in
[`../../examples/verasonics/`](../../examples/verasonics/).

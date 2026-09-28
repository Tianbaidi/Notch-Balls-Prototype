#!/usr/bin/env python3
"""Generate quiet, loopable soft and deep base-noise layers."""

from array import array
from math import cos, pi, sqrt
from pathlib import Path
from random import Random
import sys
import wave

rate = 22_050
fade = rate * 2
length = rate * 20


def make_noise(name: str, seed: int, deep: bool) -> None:
    rng = Random(seed)
    low = mid = high = 0.0
    raw = array("f")
    for _ in range(length + fade):
        white = rng.uniform(-1.0, 1.0)
        low = 0.998 * low + 0.002 * white
        mid = 0.970 * mid + 0.030 * white
        high = 0.780 * high + 0.220 * white
        value = (0.68 * low + 0.32 * mid) if deep else (
            0.38 * low + 0.44 * mid + 0.18 * high
        )
        raw.append(value)

    loop = array("f", raw[fade : fade + length])
    for index in range(fade):
        t = 0.5 - 0.5 * cos(pi * index / (fade - 1))
        tail = length - fade + index
        loop[tail] = (1 - t) * loop[tail] + t * raw[index]

    rms = sqrt(sum(sample * sample for sample in loop) / length)
    gain = min(0.70 / max(abs(sample) for sample in loop), 0.085 / rms)
    samples = array("h", (int(max(-1.0, min(1.0, sample * gain)) * 32767)
                          for sample in loop))
    if sys.byteorder != "little":
        samples.byteswap()

    output = Path(__file__).with_name(name)
    with wave.open(str(output), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes(samples.tobytes())
    print(name)


make_noise("white-noise.wav", 20260924, deep=False)
make_noise("deep-noise.wav", 20260925, deep=True)

# Third-party notices

trigger-kvm contains no third-party code. It depends on, and was informed by,
the following; the notices are reproduced here so nobody has to wonder.

## SimpleKVM (fiddyschmitt/SimpleKVM) — MIT

The NVAPI function ids and struct layouts used by `windows/trigger-kvm.ps1` and
`windows/nvapi-probe.ps1` were taken from SimpleKVM's bindings and verified
against real hardware. The ids and layouts are facts about NVIDIA's ABI; the
binding approach follows SimpleKVM's. Its licence:

    Copyright (c) 2024 Fidel Perez-Smith

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## m1ddc (waydabber/m1ddc) — MIT

The macOS switcher runs `m1ddc` as a separate program, installed by the user
through Homebrew. Nothing from it is linked or copied into this repository.
Copyright (c) 2021 waydabber.

## NVAPI (NVIDIA)

The Windows switcher calls `nvapi64.dll`, which is installed by the NVIDIA
driver and governed by its licence. No NVAPI SDK header or library is included
in this repository; functions are resolved at run time by id through
`nvapi_QueryInterface`. NVIDIA's public NVAPI SDK is itself MIT-licensed
(Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES).

## lg-input-switch (meer-cha/lg-input-switch) — GPL-3.0

Used, as a downloaded executable, by early versions of the Windows side and
removed since. No code from it was ever included here. It served as independent
corroboration of three NVAPI function ids and of the I2C packet framing, which
are facts.

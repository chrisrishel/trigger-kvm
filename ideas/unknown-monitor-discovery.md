# Making an unfamiliar monitor work

What remains unbuilt of the discovery ladder. What shipped is the contract in
`specs/configure.md` 6, 6.2 and 10: the panel's own EDID name, a dialect table
keyed by vendor and offered up front, the four-outcome check, and blind
value-walking as a stated-cost last resort.

**The constraint everything follows from: a switch cannot be verified** (hard
rules 2 and 3). Nothing below may become a detector that gates a switch; an
unreliable input that only shortens a list is safe, one that decides where to
send a write is not.

## The capabilities read

DDC/CI opcode `0xF3` asks for a capabilities string; the `0xE3` reply usually
lists supported VCP codes and, for `0x60`, the permitted values (`60(11 12
0F)`). That would turn eight MCCS guesses into three.

Deliberately last: it cannot describe `0xF4` or its values, so it cannot help
the panel that motivated the project; a panel that lies on feature reads may lie
here too; it needs an I2C read path, the fragmented multi-packet protocol and a
parser, none of which the shipping switchers have (the Intel instrument has a
read, `macos/intel-ddc-probe.c`); and it only shortens a list the person walks
while watching anyway.

**Build it when a third-party standard-DDC monitor is actually in the room.**

## The advanced escape hatch

For a panel that answers neither standard DDC nor a known dialect: **one**
specific I2C address and **one** specific value, typed by the user, behind a
strong disclaimer. Never a sweep across a range of either. Today that case ends
with "nothing known reaches this panel"; the hatch would come after that
sentence. Trigger: someone reports such a monitor (`TODO.md`).

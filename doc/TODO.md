## Munix TODO list

A list of things that need to get done within munix, organized
by priority (from highest to lowest)...

#### Bugs

- [ ] Check that the TSC deadline timer works (on real hw)

#### Issues

- [ ] Make error handling more graceful
- [ ] Rewrite `README.md` (make it much more prettier and clear)
- [ ] Clean up imports and dependencies across files
- [x] Redo the kernel initialization scheme (and fix the following issue as well)
- [x] Have initialization functions return errors, than collect them in `main.entry()`
- [ ] In-kernel stacktracing (using `std.dwarf`), since it helps on real hw

#### Nice to have

- [ ] PCI stack
- [ ] A timer layer (maybe ditch the ACPI Timer for the HPET??)
- [ ] Intel PT (Processor Trace) Support (can be used for precise examination of callgraph)

Once again, contributions are deeply apprieciated and welcomed!


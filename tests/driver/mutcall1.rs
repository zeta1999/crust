#![feature(no_std)]
#![feature(core)]
#![feature(alloc)]
#![crate_type = "lib"]
#![no_std]
#![feature(unsafe_destructor)]
extern crate core;

struct Dummy;

impl Dummy {
    fn new() -> Dummy {
        Dummy
    }

    fn do_mut(&mut self) { }
    fn do_immut(&self) { }

    fn operate(self) { }
}

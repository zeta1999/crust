#![crate_type = "lib"]

const ONE: uint = 1;

fn foo(x: uint) -> uint {
    x + ONE
}

fn crust_init() -> (uint,) { (0, ) }

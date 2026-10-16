module main

// The program entry point. The orchestrator lives in the `cli` module so it
// can import both `agent` and `tui` without a cycle; this file only wires
// `main` to it.
import cli

fn main() {
	cli.run()
}

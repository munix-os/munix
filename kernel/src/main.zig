const limine = @import("limine");

pub export var terminal_request: limine.TerminalRequest = .{};

export fn kernel_entry() callconv(.C) noreturn {
    // Ensure we got a terminal
    if (terminal_request.response) |terminal_response| {
        if (terminal_response.terminal_count < 1) {
            while (true) {
                asm volatile ("hlt");
            }
        }

        terminal_response.write(null, "Welcome to munix!");
    }

    while (true) {
        asm volatile ("hlt");
    }
}

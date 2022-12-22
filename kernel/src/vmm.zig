const limine = @import("limine");
const pmm = @import("root").pmm;

pub export var hhdm_request: limine.HhdmRequest = .{};
pub const DEFAULT_HIGHER_HALF: u64 = 0xFFFF800000000000;

pub fn toHigherHalf(ptr: usize) usize {
    if (hhdm_request.response) |resp| {
        return ptr + resp.offset;
    } else {
        return ptr + DEFAULT_HIGHER_HALF;
    }
}

pub fn fromHigherHalf(ptr: usize) usize {
    if (hhdm_request.response) |resp| {
        return ptr - resp.offset;
    } else {
        return ptr - DEFAULT_HIGHER_HALF;
    }
}

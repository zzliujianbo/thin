//! Global logical preference is configuration, not evidence of wire capability.

const cfg = @import("../core/config.zig");
const thinking = @import("../core/thinking.zig");
const Effort = @import("../presentation/activity.zig").ReasoningEffort;

pub fn preference(config: cfg.Config) ?Effort {
    if (config.registry) |registry| if (registry.reasoning_effort) |name|
        return Effort.fromName(name);
    const configured = Effort.fromName(config.model.reasoning_effort);
    // A fixed custom wire option is not a logical default to reinterpret.
    if (configured == .unknown) return null;
    return if (configured.name() != null) configured else thinking.default_level;
}

pub fn apply(config: *cfg.Config, wanted: ?Effort, global_preference: bool) ?[]const u8 {
    const cap = thinking.resolve(config.provider.base_url, config.model.name, config.model.reasoning);
    if (wanted) |level| {
        if (!cap.known) {
            // Never send a global logical preference as an unsupported raw wire
            // option. Existing fixed model options remain when no override exists.
            if (global_preference) config.model.reasoning_effort = null;
            return "Saved thinking level not applied: model capabilities unknown";
        }
        if (level == .off and !cap.levels.contains(.off)) {
            config.model.reasoning_effort = null;
            return "Thinking off unsupported by this model";
        }
        config.model.reasoning_effort = cap.effective(level.name());
        if (Effort.fromName(config.model.reasoning_effort) != level)
            return "Saved thinking level adjusted for this model; preference unchanged";
    } else config.model.reasoning_effort = cap.effective(config.model.reasoning_effort);
    return null;
}

pub fn applyConfigured(config: *cfg.Config) ?[]const u8 {
    const global = if (config.registry) |registry| registry.reasoning_effort != null else false;
    return apply(config, preference(config.*), global);
}

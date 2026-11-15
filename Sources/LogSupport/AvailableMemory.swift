#if os(iOS)
import os
#endif

/// The memory left to the app, as the logs report it.
public enum AvailableMemory {
    /// How much more memory the app may use before iOS ends it, in MB, from
    /// `os_proc_available_memory()`. Nil on macOS, which sets no such limit: log it as
    /// `availableMB` only when there is a value.
    public static var megabytes: Int? {
        #if os(iOS)
        os_proc_available_memory() / 1_048_576
        #else
        nil
        #endif
    }
}

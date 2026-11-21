-- KOReader runs plugins with LuaJIT.
std = "luajit"
-- Long log messages and comments are common, and StyLua handles line length for code.
max_line_length = false
-- Callbacks and methods often have to accept arguments they don't use.
unused_args = false

read_globals = {
    -- Provided by KOReader.
    "G_reader_settings",
}

files["test/"] = {
    globals = {
        -- The stubs replace these to simulate KOReader and the clock.
        "G_reader_settings",
        "os",
    },
}

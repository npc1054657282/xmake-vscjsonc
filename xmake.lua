add_rules("mode.debug", "mode.release")

target("example")
    set_kind("binary")
    add_files("example/**.c")
    on_config(function(target)
        if not os.isfile("$(scriptdir)/runconf.lua") then
            os.trycp("$(scriptdir)/example-runconf.lua", "$(scriptdir)/runconf.lua")
        end
        local runconf = (import("runconf", {try = true, anonymous = true}) or (function() return {ARGS="failed"} end))()
        local args = runconf.ARGS or {"failed"}
        target:set("runargs", args)
        local jsonc_editor = import("module.vscjsonc")(".vscode/settings.json")
        jsonc_editor:set({"xmake.debuggingTargetsArguments", "example"}, vscjsonc.array(args), {comment = "xmake插件调试时使用的参数"})
        jsonc_editor:save()
    end)
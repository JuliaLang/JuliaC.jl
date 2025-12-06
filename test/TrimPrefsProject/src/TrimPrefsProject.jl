module TrimPrefsProject

using Preferences

# Read the trim_enabled preference at compile time from the Preferences package
# This preference is set by JuliaC in the temporary depot during compilation
const TRIM_ENABLED = Preferences.load_preference(Preferences, "trim_enabled", false)::Bool

function @main(ARGS)
    if TRIM_ENABLED
        println(Core.stdout, "TRIM_MODE_ENABLED")
    else
        println(Core.stdout, "TRIM_MODE_DISABLED")
    end
    return 0
end

end # module TrimPrefsProject

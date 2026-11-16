# Reaches `TrimPrefDep` only through `TrimPrefMid`, so that the preference has to be set
# for a package that is not a direct dependency of the project being compiled.
module TrimPrefApp

using TrimPrefMid

function @main(args::Vector{String})::Cint
    println(Core.stdout, TrimPrefMid.describe())
    return 0
end

end

module LibJLOptionsCheck

Base.@ccallable function jc_get_handle_signals()::Cint
    return Cint(Base.JLOptions().handle_signals)
end

Base.@ccallable function jc_get_nthreads()::Cint
    return Cint(Base.JLOptions().nthreads)
end

Base.@ccallable function jc_get_nthreadpools()::Cint
    return Cint(Base.JLOptions().nthreadpools)
end

end

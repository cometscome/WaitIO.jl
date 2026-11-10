# Serialize native WaitIO access and the Julia ownership registries. Blocking
# request waits poll under short locks, allowing another thread to post a match.
const _call_lock=ReentrantLock()
macro locked(def)
    def.head==:function || error("@locked expects a function definition")
    body=def.args[2]
    def.args[2]=quote
        lock(_call_lock)
        try
            $body
        finally
            unlock(_call_lock)
        end
    end
    esc(def)
end

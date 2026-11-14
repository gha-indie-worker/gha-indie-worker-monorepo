package dev.oreslang;

import com.oracle.truffle.api.CallTarget;
import com.oracle.truffle.api.TruffleLanguage;
import dev.oreslang.runtime.OresContext;

public final class OresLanguage extends TruffleLanguage<OresContext> {
    public static final String ID = "ores";

    @Override
    protected OresContext createContext(Env env) {
        return new OresContext(this, env);
    }

    @Override
    protected CallTarget parse(ParsingRequest request) {
        throw new UnsupportedOperationException("validation stub");
    }
}

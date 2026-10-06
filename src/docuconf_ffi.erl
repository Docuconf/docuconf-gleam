-module(docuconf_ffi).
-export([regex_compile/1, regex_matches/2, json_decode/1, read_file/1, file_info/1,
         write_file/2, file_exists/1, now_unix/0, print_error/1, pem_certificates/1, pem_count/1,
         tls_check/7, keystore_verify/3]).

%% ---- regex (RE2 semantics are prepared on the Gleam side) -------------------

regex_compile(Pattern) ->
    case re:compile(Pattern, [unicode, dollar_endonly]) of
        {ok, _} -> {ok, nil};
        {error, {Msg, Pos}} ->
            {error, unicode:characters_to_binary(io_lib:format("invalid pattern at ~p: ~s", [Pos, Msg]))}
    end.

regex_matches(Pattern, Value) ->
    case unicode:characters_to_binary(Value) of
        Bin when is_binary(Bin) ->
            case re:run(Bin, Pattern, [unicode, dollar_endonly, {capture, none}]) of
                match -> true;
                _ -> false
            end;
        _ -> false
    end.

%% ---- JSON (OTP 27 json module) ----------------------------------------------

json_decode(Bin) ->
    try
        {ok, json:decode(Bin, ok, #{null => nil})}
    of
        {ok, {Value, ok, Rest}} ->
            case string:trim(Rest) of
                <<>> -> {ok, Value};
                _ -> {error, <<"unexpected data after the JSON value">>}
            end
    catch
        error:{invalid_byte, B} ->
            {error, unicode:characters_to_binary(io_lib:format("invalid byte ~p", [B]))};
        error:unexpected_end -> {error, <<"unexpected end of input">>};
        error:{unexpected_sequence, _} -> {error, <<"invalid escape sequence">>};
        error:_ -> {error, <<"invalid JSON">>}
    end.

%% ---- files ------------------------------------------------------------------

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

file_info(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} ->
            Type = case element(3, Info) of
                regular -> <<"regular">>;
                directory -> <<"directory">>;
                _ -> <<"other">>
            end,
            {ok, {Type, element(2, Info)}};
        {error, Reason} -> {error, atom_to_binary(Reason)}
    end.

write_file(Path, Bin) ->
    _ = file:write_file(Path, Bin),
    nil.

file_exists(Path) -> filelib:is_file(Path).

now_unix() -> os:system_time(second).

print_error(Msg) ->
    io:put_chars(standard_error, [Msg, $\n]),
    nil.

%% ---- certificates -----------------------------------------------------------

%% {Total CERTIFICATE blocks, DERs of those that parse}
pem_certificates(Pem) ->
    Entries = try public_key:pem_decode(Pem) catch _:_ -> [] end,
    Certs = [Der || {'Certificate', Der, _} <- Entries],
    Good = [Der || Der <- Certs, parses(Der)],
    {length(Certs), Good}.

pem_count(Pem) ->
    {Total, Good} = pem_certificates(Pem),
    {Total, length(Good)}.

parses(Der) ->
    try public_key:pkix_decode_cert(Der, otp), true catch _:_ -> false end.

-define(RSA, {1, 2, 840, 113549, 1, 1, 1}).
-define(EC, {1, 2, 840, 10045, 2, 1}).
-define(ED25519, {1, 3, 101, 112}).
-define(ED448, {1, 3, 101, 113}).

%% Returns a list of {Code, Message}. CaPem is <<>> when requireCA is unset.
tls_check(CertPem, KeyPem, CaPem, DnsNames, KeyAlgs, MinRemaining, Now) ->
    case pem_certificates(CertPem) of
        {0, _} -> [{<<"certificate_invalid">>, <<"tls.crt holds no PEM certificate">>}];
        {N, Good} when length(Good) < N ->
            [{<<"certificate_invalid">>, <<"tls.crt holds a certificate that cannot be parsed">>}];
        {_, [Leaf | _] = Chain} ->
            Otp = public_key:pkix_decode_cert(Leaf, otp),
            lists:append([
                key_check(KeyPem, Otp),
                validity_check(Otp, MinRemaining, Now),
                [{<<"certificate_name_mismatch">>, <<"certificate does not cover ", Name/binary>>}
                 || Name <- DnsNames, not hostname_ok(Leaf, Name)],
                alg_check(Otp, KeyAlgs),
                chain_check(Chain, CaPem)
            ])
    end.

key_check(KeyPem, Otp) ->
    try public_key:pem_decode(KeyPem) of
        [{_, _, not_encrypted} = Entry | _] ->
            Key = public_key:pem_entry_decode(Entry),
            case key_matches(Key, Otp) of
                true -> [];
                false -> [{<<"key_mismatch">>, <<"tls.key does not match the certificate in tls.crt">>}]
            end;
        [_ | _] -> [{<<"certificate_invalid">>, <<"tls.key is encrypted">>}];
        [] -> [{<<"certificate_invalid">>, <<"tls.key holds no PEM private key">>}]
    catch
        _:_ -> [{<<"certificate_invalid">>, <<"tls.key is not a readable PEM private key">>}]
    end.

spki(Otp) -> element(8, element(2, Otp)).

key_matches(Key, Otp) ->
    {'OTPSubjectPublicKeyInfo', {'PublicKeyAlgorithm', Oid, Params}, Pub} = spki(Otp),
    Msg = <<"docuconf key match probe">>,
    {Digest, Public} = case Oid of
        ?RSA -> {sha256, Pub};
        ?EC -> {sha256, {Pub, Params}};
        O when O =:= ?ED25519; O =:= ?ED448 -> {none, {Pub, {namedCurve, O}}};
        _ -> {sha256, Pub}
    end,
    try
        Sig = public_key:sign(Msg, Digest, Key),
        public_key:verify(Msg, Digest, Sig, Public)
    catch
        _:_ -> false
    end.

validity_check(Otp, MinRemaining, Now) ->
    {'Validity', From, To} = element(6, element(2, Otp)),
    F = asn1_time(From),
    T = asn1_time(To),
    if
        Now < F -> [{<<"certificate_invalid">>, <<"certificate is not valid yet">>}];
        Now > T -> [{<<"certificate_invalid">>, <<"certificate has expired">>}];
        MinRemaining > 0, T - Now < MinRemaining ->
            Msg = io_lib:format("certificate expires in ~bs, less than minRemaining (~bs)", [T - Now, MinRemaining]),
            [{<<"certificate_expiring">>, unicode:characters_to_binary(Msg)}];
        true -> []
    end.

asn1_time({utcTime, T}) ->
    [Y1, Y2 | Rest] = T,
    Y = list_to_integer([Y1, Y2]),
    asn1_time({generalTime, integer_to_list(if Y >= 50 -> 1900 + Y; true -> 2000 + Y end) ++ Rest});
asn1_time({generalTime, T}) ->
    [Y, Mo, D, H, Mi, S] = [list_to_integer(lists:sublist(T, P, L))
                            || {P, L} <- [{1, 4}, {5, 2}, {7, 2}, {9, 2}, {11, 2}, {13, 2}]],
    calendar:datetime_to_gregorian_seconds({{Y, Mo, D}, {H, Mi, S}}) - 62167219200.

hostname_ok(Leaf, Name) ->
    Match = [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}],
    public_key:pkix_verify_hostname(Leaf, [{dns_id, binary_to_list(Name)}], Match).

alg_name(Otp) ->
    {'OTPSubjectPublicKeyInfo', {'PublicKeyAlgorithm', Oid, _}, _} = spki(Otp),
    case Oid of
        ?RSA -> <<"RSA">>;
        ?EC -> <<"ECDSA">>;
        ?ED25519 -> <<"Ed25519">>;
        _ -> <<"other">>
    end.

alg_check(_Otp, []) -> [];
alg_check(Otp, Algs) ->
    Alg = alg_name(Otp),
    case lists:member(Alg, Algs) of
        true -> [];
        false -> [{<<"certificate_invalid">>, <<"key algorithm ", Alg/binary, " is not allowed">>}]
    end.

chain_check(_Chain, <<>>) -> [];
chain_check([Leaf | Intermediates], CaPem) ->
    case pem_certificates(CaPem) of
        {_, []} -> [{<<"certificate_invalid">>, <<"ca.crt holds no parseable certificate">>}];
        {_, Anchors} ->
            Ok = lists:any(
                   fun(Anchor) ->
                           Path = lists:reverse([I || I <- Intermediates, I =/= Anchor]) ++ [Leaf],
                           case public_key:pkix_path_validation(Anchor, Path, [{verify_fun, {fun verify/3, nil}}]) of
                               {ok, _} -> true;
                               _ -> false
                           end
                   end, Anchors),
            case Ok of
                true -> [];
                false -> [{<<"certificate_invalid">>, <<"tls.crt does not chain to a certificate in ca.crt">>}]
            end
    end.

verify(_, {bad_cert, cert_expired}, S) -> {valid, S};
verify(_, {bad_cert, R}, _) -> {fail, R};
verify(_, {extension, _}, S) -> {unknown, S};
verify(_, _, S) -> {valid, S}.

%% ---- keystores --------------------------------------------------------------
%%
%% OTP has no PKCS#12 reader, so the PFX structure (DER) is parsed here and
%% its integrity MAC verified (RFC 7292: PKCS#12 key derivation and HMAC with
%% SHA-1 or SHA-2). A correct MAC proves the password is right and the file is
%% intact; the encrypted contents are not decrypted. JKS and JCEKS stores are
%% checked with their SHA-1 integrity digest. Returns {ok, nil} or
%% {error, Reason}. Mirrors keystoreVerify in docuconf_ffi.mjs.

keystore_verify(<<"pkcs12">>, Der, Password) -> pkcs12(Der, Password);
keystore_verify(<<"jks">>, Bin, Password) -> jks(Bin, Password).

-define(PBMAC1, {1, 2, 840, 113549, 1, 5, 14}).

mac_hash({1, 3, 14, 3, 2, 26}) -> {sha, 64};
mac_hash({2, 16, 840, 1, 101, 3, 4, 2, 4}) -> {sha224, 64};
mac_hash({2, 16, 840, 1, 101, 3, 4, 2, 1}) -> {sha256, 64};
mac_hash({2, 16, 840, 1, 101, 3, 4, 2, 2}) -> {sha384, 128};
mac_hash({2, 16, 840, 1, 101, 3, 4, 2, 3}) -> {sha512, 128};
mac_hash(_) -> unknown.

pkcs12(Der, Password) ->
    try pkcs12_mac(Der) of
        {ok, {Hash, Block, Digest, Salt, Iterations, Data}} ->
            %% OpenSSL encodes an empty password as the two-byte BMP
            %% terminator, some other tools as nothing at all; try both.
            Candidates = case Password of
                <<>> -> [bmp(<<>>), <<>>];
                _ -> [bmp(Password)]
            end,
            Ok = lists:any(
                   fun(Pw) ->
                           Key = kdf(Hash, Block, Pw, Salt, 3, Iterations, byte_size(Digest)),
                           crypto:mac(hmac, Hash, Key, Data) =:= Digest
                   end, Candidates),
            case Ok of
                true -> {ok, nil};
                false -> {error, <<"wrong password or corrupted file: the integrity MAC does not match">>}
            end;
        {error, _} = E -> E
    catch
        throw:{bad, Msg} -> {error, Msg};
        _:_ -> {error, <<"not a DER-encoded PKCS#12 (PFX) file">>}
    end.

pkcs12_mac(Der) ->
    {16#30, Pfx, <<>>} = tlv(Der),
    [{16#02, _Version}, {16#30, AuthSafe} | Mac] = seq(Pfx),
    Data = case seq(AuthSafe) of
        [{16#06, _}, {16#A0, Explicit}] ->
            case tlv(Explicit) of
                {16#04, D, <<>>} -> D;
                _ -> throw({bad, <<"PKCS#12 authSafe is not plain data (public-key integrity mode is not supported)">>})
            end;
        _ -> throw({bad, <<"PKCS#12 authSafe is not plain data (public-key integrity mode is not supported)">>})
    end,
    MacData = case Mac of
        [{16#30, M}] -> M;
        [] -> throw({bad, <<"the PKCS#12 file has no integrity MAC, so its password cannot be checked">>});
        _ -> throw({bad, <<"malformed PKCS#12 MacData">>})
    end,
    {DigestInfo, Salt, Rest} = case seq(MacData) of
        [{16#30, DI}, {16#04, S} | R] -> {DI, S, R};
        _ -> throw({bad, <<"malformed PKCS#12 MacData">>})
    end,
    [{16#30, Alg}, {16#04, Digest}] = seq(DigestInfo),
    [{16#06, OidDer} | _] = seq(Alg),
    Iterations = case Rest of
        [{16#02, I}] -> binary:decode_unsigned(I);
        [] -> 1
    end,
    Oid = decode_oid(OidDer),
    case {mac_hash(Oid), Oid} of
        {{Hash, Block}, _} -> {ok, {Hash, Block, Digest, Salt, Iterations, Data}};
        {unknown, ?PBMAC1} -> {error, <<"PBMAC1 integrity MACs are not supported yet">>};
        {unknown, _} ->
            Dotted = lists:join(".", [integer_to_list(A) || A <- tuple_to_list(Oid)]),
            {error, unicode:characters_to_binary(["unsupported MAC digest ", Dotted])}
    end.

bmp(Password) ->
    <<(unicode:characters_to_binary(Password, utf8, {utf16, big}))/binary, 0, 0>>.

%% RFC 7292 appendix B.2.
kdf(Hash, V, Password, Salt, Id, Iterations, N) ->
    D = binary:copy(<<Id>>, V),
    I0 = <<(stretch(Salt, V))/binary, (stretch(Password, V))/binary>>,
    U = byte_size(crypto:hash(Hash, <<>>)),
    C = (N + U - 1) div U,
    {Out, _} = lists:foldl(
                 fun(_, {Acc, I}) ->
                         A = lists:foldl(fun(_, X) -> crypto:hash(Hash, X) end,
                                         <<D/binary, I/binary>>, lists:seq(1, Iterations)),
                         B = binary:decode_unsigned(binary:part(stretch(A, V), 0, V)),
                         Mask = (1 bsl (V * 8)) - 1,
                         I2 = << <<((binary:decode_unsigned(Blk) + B + 1) band Mask):(V * 8)>>
                                 || <<Blk:V/binary>> <= I >>,
                         {<<Acc/binary, A/binary>>, I2}
                 end, {<<>>, I0}, lists:seq(1, C)),
    binary:part(Out, 0, N).

%% Repeats Bin to fill V * ceil(len/V) bytes (empty stays empty).
stretch(<<>>, _V) -> <<>>;
stretch(Bin, V) ->
    Len = V * ((byte_size(Bin) + V - 1) div V),
    binary:part(binary:copy(Bin, Len div byte_size(Bin) + 1), 0, Len).

tlv(<<Tag, 16#80, _/binary>>) when Tag =:= 16#30; Tag =:= 16#24; Tag =:= 16#A0 ->
    throw({bad, <<"BER indefinite-length encoding is not supported; convert with openssl pkcs12">>});
tlv(<<Tag, Len, Rest/binary>>) when Len < 16#80, byte_size(Rest) >= Len ->
    <<Value:Len/binary, Rest2/binary>> = Rest,
    {Tag, Value, Rest2};
tlv(<<Tag, 1:1, N:7, Rest/binary>>) when N >= 1, N =< 4, byte_size(Rest) >= N ->
    <<Len:(N * 8), Rest2/binary>> = Rest,
    true = byte_size(Rest2) >= Len,
    <<Value:Len/binary, Rest3/binary>> = Rest2,
    {Tag, Value, Rest3}.

seq(<<>>) -> [];
seq(Bin) ->
    {Tag, Value, Rest} = tlv(Bin),
    [{Tag, Value} | seq(Rest)].

decode_oid(<<First, Rest/binary>>) ->
    {Arcs, _} = lists:foldl(
                  fun({More, Bits}, {Acc, Cur}) ->
                          Cur2 = (Cur bsl 7) bor Bits,
                          case More of
                              1 -> {Acc, Cur2};
                              0 -> {[Cur2 | Acc], 0}
                          end
                  end, {[], 0}, [{M, B} || <<M:1, B:7>> <= Rest]),
    list_to_tuple([First div 40, First rem 40 | lists:reverse(Arcs)]).

jks(<<Magic:32, _/binary>> = Content, Password)
  when (Magic =:= 16#FEEDFEED orelse Magic =:= 16#CECECECE) andalso byte_size(Content) > 20 ->
    Body = binary:part(Content, 0, byte_size(Content) - 20),
    Digest = binary:part(Content, byte_size(Content) - 20, 20),
    Pw = unicode:characters_to_binary(Password, utf8, {utf16, big}),
    case crypto:hash(sha, [Pw, <<"Mighty Aphrodite">>, Body]) =:= Digest of
        true -> {ok, nil};
        false -> {error, <<"wrong password or corrupted file: the integrity digest does not match">>}
    end;
jks(_, _) -> {error, <<"not a JKS or JCEKS keystore">>}.

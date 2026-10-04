-module(docuconf_ffi).
-export([regex_compile/1, regex_matches/2, json_decode/1, read_file/1, file_info/1,
         write_file/2, file_exists/1, now_unix/0, print_error/1, pem_certificates/1, pem_count/1,
         tls_check/7]).

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

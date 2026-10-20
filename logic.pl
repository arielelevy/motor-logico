:- module(logic, [logic_request/3, engine_version/1]).
:- use_module(library(assoc)).
:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(occurs)).
:- use_module(library(pairs)).
:- use_module(library(sha)).
:- use_module(library(time)).
:- use_module(store).

% Contratos 2 y 3, dominio logic: Datalog estratificado con negación, comparaciones,
% restricciones de integridad, pruebas y almacenes persistentes opcionales. El 3 suma
% agregados, aritmética no recursiva, fuentes de hechos, huella del programa y
% explicación de fallos; el 2 conserva su entrada y su salida.
% Las reglas llegan como datos y se interpretan contra hechos propios: nunca se
% llama a un goal recibido ni se consulta código del cliente o del almacén.

:- dynamic pred_name/2, rplan/5, rule_def/2, smemo/3.

engine_version("0.2.0").

err(Code, Message) :- throw(motor_error(Code, Message)).
err(Code, Format, Args) :- format(string(M), Format, Args), throw(motor_error(Code, M)).

% Versión del contrato de la consulta en curso (un proceso por consulta).
version(V) :- nb_getval(logic_version, V).
v3 :- version(3).

limit(seconds, 5, 1, 30).
limit(max_results, 100, 1, 10000).
limit(proof_depth, 12, 1, 64).
max_items(facts, 100000).
max_items(rules, 5000).
max_items(constraints, 1000).
max_items(queries, 100).
proof_budget(300).
agg_items(50).

%% Solicitud

logic_request(V, In0, Out) :-
    nb_setval(logic_version, V),
    normalize(In0, In),
    Keys = [contract, domain, store, expect_revision, assert, retract, facts, rules,
            constraints, queries, explain, export, limits],
    (V == 3 -> append(Keys, [explain_failures], Allowed) ; Allowed = Keys),
    check_keys(In, Allowed, "la consulta"),
    (get_dict(domain, In, "logic") -> true ; err(unsupported_domain, "El contrato ~w sólo admite domain \"logic\"", [V])),
    settings(In, Settings),
    parse_section(In, Local),
    items(In, queries, QJ), numlist_for(QJ, QIdx), maplist(parse_query, QIdx, QJ, Queries),
    changes(In, Changes),
    bool_opt(In, export, Export),
    (get_dict(store, In, SJ) -> store_name(SJ, Name) ; Name = none),
    (   get_dict(expect_revision, In, Exp)
    ->  (integer(Exp), Exp >= 0 -> true ; err(invalid_request, "expect_revision debe ser un entero >= 0"))
    ;   Exp = any
    ),
    (   Name == none
    ->  (Changes == none, Exp == any, Export == false -> true
        ; err(store_required, "assert, retract, expect_revision y export requieren store")),
        solve(Local, Queries, Settings, Result), StoreOut = null
    ;   Changes == none
    ->  load(Name, Stored), check_revision(Exp, Stored),
        solve_with(Stored, Local, Queries, Settings, Result),
        store_out(Name, Stored, false, Export, StoreOut)
    ;   with_store_lock(Name, (
            load(Name, S0), check_revision(Exp, S0), apply_changes(Changes, S0, S1, Changed),
            solve_with(S1, Local, Queries, Settings, Result),
            (Changed == true -> store_format(S1, Format), store_save(Name, Format, S1) ; true),
            store_out(Name, S1, Changed, Export, StoreOut)))
    ),
    Result = result(Answers, Violations, Stats, Hash),
    (Violations == [] -> Consistent = true ; Consistent = false),
    Out0 = _{contract:V, domain:logic, store:StoreOut, answers:Answers,
             consistent:Consistent, violations:Violations, stats:Stats},
    (   V == 3
    ->  engine_version(EV), Out = Out0.put(_{engine:_{name:"motor-logico", version:EV}, program_hash:Hash})
    ;   Out = Out0
    ).

% Toda la entrada: junta pares surrogate (json_read los deja separados y no se podrían
% volver a leer del almacén), rechaza los sueltos y lleva 1.0 a 1 y -0.0 a 0.
normalize(D, N) :- is_dict(D), !, dict_pairs(D, T, P0), maplist([K-V, K-W]>>normalize(V, W), P0, P), dict_pairs(N, T, P).
normalize(L, N) :- is_list(L), !, maplist(normalize, L, N).
normalize(S, N) :- string(S), !, string_codes(S, C0), surrogates(C0, C), string_codes(N, C).
normalize(F, N) :- float(F), !, norm_num(F, N).
normalize(X, X).
norm_num(F, N) :- float(F), F =:= truncate(F), abs(F) < 9007199254740992, !, N is truncate(F).
norm_num(X, X).
surrogates([], []).
surrogates([H, L|T], [C|R]) :- between(0xD800, 0xDBFF, H), between(0xDC00, 0xDFFF, L), !,
    C is 0x10000 + ((H - 0xD800) << 10) + (L - 0xDC00), surrogates(T, R).
surrogates([C|_], _) :- between(0xD800, 0xDFFF, C), !, err(invalid_term, "Texto con un surrogate UTF-16 suelto").
surrogates([C|T], [C|R]) :- surrogates(T, R).

numlist_for(L, Idx) :- length(L, N), (N =:= 0 -> Idx = [] ; numlist(1, N, Idx)).

settings(In, _{explain:E, failures:F, seconds:S, max_results:M, proof_depth:D}) :-
    bool_opt(In, explain, E), bool_opt(In, explain_failures, F),
    (   get_dict(limits, In, L)
    ->  (is_dict(L) -> check_keys(L, [seconds, max_results, proof_depth], "limits")
        ; err(invalid_request, "limits debe ser un objeto"))
    ;   L = _{}
    ),
    setting(L, seconds, S), setting(L, max_results, M), setting(L, proof_depth, D).
setting(L, K, V) :-
    limit(K, Def, Min, Max),
    (   get_dict(K, L, V0)
    ->  (integer(V0), between(Min, Max, V0) -> V = V0
        ; err(invalid_limit, "limits.~w debe ser un entero entre ~w y ~w", [K, Min, Max]))
    ;   V = Def
    ).

bool_opt(D, K, V) :-
    (   get_dict(K, D, V0)
    ->  (memberchk(V0, [true, false]) -> V = V0 ; err(invalid_request, "~w debe ser booleano", [K]))
    ;   V = false
    ).

check_keys(D, Allowed, Where) :-
    (is_dict(D) -> true ; err(invalid_request, "~s debe ser un objeto JSON", [Where])),
    dict_pairs(D, _, Pairs),
    forall(member(K-_, Pairs),
        (memberchk(K, Allowed) -> true ; err(invalid_request, "Campo desconocido ~w en ~s", [K, Where]))).

items(D, K, L) :-
    (   get_dict(K, D, L)
    ->  (is_list(L) -> true ; err(invalid_request, "~w debe ser una lista", [K])),
        (max_items(K, Max), length(L, N), N > Max -> err(too_large, "~w admite hasta ~w elementos", [K, Max]) ; true)
    ;   L = []
    ).

parse_section(D, program(Facts, Rules, Constraints)) :-
    items(D, facts, FJ), maplist(parse_fact, FJ, Facts),
    items(D, rules, RJ), maplist(parse_rule, RJ, Rules),
    items(D, constraints, CJ), maplist(parse_constraint, CJ, Constraints).

% changes(HechosAgregados, Reglas, Restricciones, HechosQuitados, IdsReglas, IdsRestricciones)
changes(In, Changes) :-
    (   get_dict(assert, In, A)
    ->  check_keys(A, [facts, rules, constraints], "assert"), parse_section(A, program(AF, AR, AC))
    ;   AF = [], AR = [], AC = []
    ),
    (   get_dict(retract, In, R)
    ->  check_keys(R, [facts, rules, constraints], "retract"),
        items(R, facts, DFJ),
        forall(member(J, DFJ), (is_dict(J), get_dict(source, J, _), v3
            -> err(invalid_fact, "retract quita el hecho con todas sus fuentes; no lleva source") ; true)),
        maplist(parse_fact, DFJ, DF),
        items(R, rules, DR), items(R, constraints, DC), maplist(id_string, DR), maplist(id_string, DC)
    ;   DF = [], DR = [], DC = []
    ),
    (   AF == [], AR == [], AC == [], DF == [], DR == [], DC == []
    ->  Changes = none
    ;   Changes = changes(AF, AR, AC, DF, DR, DC)
    ).

check_revision(any, _) :- !.
check_revision(Exp, store(Rev, _, _, _)) :-
    (Exp =:= Rev -> true ; err(conflict, "Revisión esperada ~w, actual ~w", [Exp, Rev])).

%% Almacén

% Los hechos quedan como fact(Pred, Args, Fuentes), una entrada por hecho, ordenados.
load(Name, store(Rev, Facts, Rules, Constraints)) :-
    store_load(Name, Format, store(Rev, Raw, Rules, Constraints)),
    (   Format == 2, \+ v3
    ->  err(corrupt_store, "El almacén ~s es del contrato 3; consultalo con contract 3", [Name])
    ;   true
    ),
    (   maplist(stored_fact(Format), Raw, Facts0), maplist(valid_rule(Format), Rules),
        maplist(valid_constraint(Format), Constraints)
    ->  true
    ;   err(corrupt_store, "El almacén ~s contiene términos con forma inválida", [Name])
    ),
    merge_facts(Facts0, Facts),
    maplist(check_rule, Rules), maplist(check_constraint, Constraints).
stored_fact(1, fact(P, Vs), fact(P, Vs, [])) :- valid_fact(P, Vs).
stored_fact(2, fact(P, Vs, S), fact(P, Vs, S)) :- valid_fact(P, Vs), is_list(S), maplist(source_name, S), sort(S, S).

% Un hecho es predicado y argumentos; sus fuentes son un conjunto: repetirlo las une.
merge_facts(L, M) :- msort(L, S), merge_sorted(S, M).
merge_sorted([], []).
merge_sorted([fact(P, V, S1), fact(P, V, S2)|T], M) :- !, ord_union(S1, S2, S), merge_sorted([fact(P, V, S)|T], M).
merge_sorted([F|T], [F|M]) :- merge_sorted(T, M).

apply_changes(changes(AF, AR, AC, DF, DR, DC), store(Rev, F0, R0, C0), store(Rev1, F, R, C), Changed) :-
    maplist([fact(P, Vs, _), P-Vs]>>true, DF, DK0), sort(DK0, DK),
    exclude([fact(P, Vs, _)]>>ord_memberchk(P-Vs, DK), F0, F1),
    append(F1, AF, F2), merge_facts(F2, F),
    upsert(AR, DR, R0, R), upsert(AC, DC, C0, C),
    store_limits(F, R, C),
    (F == F0, R == R0, C == C0 -> Changed = false, Rev1 = Rev ; Changed = true, Rev1 is Rev + 1).
% Reemplaza por id y deja la lista ordenada por id.
upsert(New, Drop, Old, Result) :-
    maplist(arg(1), New, NewIds), sort(NewIds, Unique), length(NewIds, N), length(Unique, U),
    (N =:= U -> true ; err(duplicate_id, "assert repite un id")),
    append(Drop, NewIds, Remove),
    exclude([T]>>(arg(1, T, Id), memberchk(Id, Remove)), Old, Kept),
    append(Kept, New, All), sort(1, @<, All, Result).
store_limits(F, R, C) :-
    forall(member(K-L, [facts-F, rules-R, constraints-C]),
        (max_items(K, Max), length(L, N), N > Max -> err(too_large, "El almacén admite hasta ~w ~w", [Max, K]) ; true)).

store_out(Name, store(Rev, F, R, C), Changed, Export, Out) :-
    length(F, NF), length(R, NR), length(C, NC),
    Out0 = _{name:Name, revision:Rev, facts:NF, rules:NR, constraints:NC, changed:Changed},
    (   Export == true
    ->  foldl(fact_json, F, FJ, []), maplist(rule_json, R, RJ), maplist(constraint_json, C, CJ),
        Out = Out0.put(content, _{facts:FJ, rules:RJ, constraints:CJ})
    ;   Out = Out0
    ).

% El orden de inserción decide qué derivación queda como prueba. En el contrato 2 es el de
% siempre: almacén primero, luego la consulta. En el 3 es canónico (hechos fusionados y
% ordenados, reglas y restricciones por id), así el mismo program_hash da la misma salida.
% Todo esto corre fuera de los límites de la evaluación.
solve_with(store(_, SF, SR, SC), program(LF, LR, LC), Queries, Settings, Result) :-
    maplist(arg(1), SR, SRI), maplist(arg(1), LR, LRI), append(SRI, LRI, RI),
    maplist(arg(1), SC, SCI), maplist(arg(1), LC, LCI), append(SCI, LCI, CI),
    unique_ids(RI, "regla"), unique_ids(CI, "restricción"),
    append(SR, LR, Rules0), append(SC, LC, Constraints0),
    (   v3
    ->  append(SF, LF, AllF), merge_facts(AllF, Merged),
        maplist([fact(P, Vs, _), P-Vs]>>true, SF, SK0), sort(SK0, SK),
        maplist([fact(P, Vs, S), fact(P, Vs, S)-O]>>(ord_memberchk(P-Vs, SK) -> O = stored ; O = given), Merged, Facts),
        sort(1, @<, Rules0, Rules), sort(1, @<, Constraints0, Constraints),
        program_hash(Merged, Rules, Constraints, Hash)
    ;   maplist([F, F-stored]>>true, SF, SFO), maplist([F, F-given]>>true, LF, LFO),
        append(SFO, LFO, Facts), Rules = Rules0, Constraints = Constraints0, Hash = none
    ),
    solve_program(program(Facts, Rules, Constraints), Queries, Settings, Result0),
    Result0 = result(A, V, S), Result = result(A, V, S, Hash).

% Formato mínimo del almacén: el 2 sólo si hay fuentes, agregados u op. Así el contrato 2
% puede seguir leyendo lo que escribió el 3 mientras no use nada nuevo.
store_format(store(_, F, R, C), Format) :-
    (   ( member(fact(_, _, S), F), S \== []
        ; member(T, R), arg(3, T, B), member(I, B), new_item(I)
        ; member(T, C), arg(3, T, B), member(I, B), new_item(I) )
    ->  Format = 2
    ;   Format = 1
    ).
new_item(agg(_, _, _, _)).
new_item(op(_, _, _, _)).
solve(program(LF, LR, LC), Queries, Settings, Result) :-
    solve_with(store(0, [], [], []), program(LF, LR, LC), Queries, Settings, Result).

unique_ids(Ids, What) :-
    msort(Ids, Sorted),
    (append(_, [X, X|_], Sorted) -> err(duplicate_id, "Id de ~s repetido: ~s", [What, X]) ; true).

% Huella del programa: SHA-256 de los términos canónicos ordenados. No depende del orden ni
% de si un hecho vino del almacén o de la consulta.
program_hash(Facts, Rules, Constraints, Hash) :-
    append([Facts, Rules, Constraints], Terms),
    maplist([T, S]>>with_output_to(string(S), write_canonical(T)), Terms, Strings),
    msort(Strings, Sorted), atomic_list_concat(Sorted, '\n', Text),
    sha_hash(Text, H, [algorithm(sha256), encoding(utf8)]), hash_atom(H, Hex),
    format(string(Hash), "sha256:~w", [Hex]).

%% Parseo: JSON -> términos internos (sólo datos)
% Términos: v(Nombre) variable ("?X"; "?_" anónima), c(Valor) constante.
% "??x" es la constante "?x". Literales: lit(Pred, Args). Hechos: fact(Pred, Valores, Fuentes).
% Cuerpo: pos(Lit), neg(Lit), cmp(Op, A, B); en el contrato 3 también
% agg(Op, Lit, Valor|none, Como) y op(Op, A, B, Como).

parse_fact(J, fact(P, Vs, Srcs)) :-
    (v3 -> Keys = [pred, args, source] ; Keys = [pred, args]),
    parse_lit(J, Keys, "hecho", lit(P, Ts)),
    maplist(fact_value(P), Ts, Vs),
    (   get_dict(source, J, S)
    ->  (source_name(S) -> Srcs = [S] ; err(invalid_fact, "source del hecho ~s debe ser [a-z][a-z0-9_]{0,31}", [P]))
    ;   Srcs = []
    ).
fact_value(_, c(V), V) :- !.
fact_value(P, _, _) :- err(invalid_fact, "El hecho ~s tiene variables; los hechos son ground", [P]).
source_name(S) :-
    string(S), string_length(S, L), between(1, 32, L), string_codes(S, [C|Cs]),
    between(0'a, 0'z, C), forall(member(X, Cs), (between(0'a, 0'z, X) ; between(0'0, 0'9, X) ; X == 0'_)).

parse_rule(J, rule(Id, Head, Body)) :-
    check_keys(J, [id, head, body], "regla"),
    (get_dict(id, J, Id), id_string(Id) -> true ; err(invalid_rule, "Cada regla necesita id")),
    (get_dict(head, J, HJ) -> parse_lit(HJ, [pred, args], "cabeza", Head) ; err(invalid_rule, "La regla ~s no tiene head", [Id])),
    items(J, body, BJ), maplist(parse_body, BJ, Body),
    check_rule(rule(Id, Head, Body)).

parse_constraint(J, constraint(Id, Message, Body)) :-
    check_keys(J, [id, message, body], "restricción"),
    (get_dict(id, J, Id), id_string(Id) -> true ; err(invalid_constraint, "Cada restricción necesita id")),
    (get_dict(message, J, Message) -> (string(Message) -> true ; err(invalid_constraint, "message debe ser texto")) ; Message = ""),
    items(J, body, BJ), maplist(parse_body, BJ, Body),
    (Body == [] -> err(invalid_constraint, "La restricción ~s necesita body", [Id]) ; true),
    check_constraint(constraint(Id, Message, Body)).

parse_body(J, Item) :-
    (is_dict(J) -> true ; err(invalid_rule, "Cada literal del body debe ser un objeto")),
    (   get_dict(cmp, J, Op)
    ->  check_keys(J, [cmp, args], "comparación"),
        (cmp_op(Op) -> true ; err(invalid_rule, "cmp admite = != < <= > >=")),
        (get_dict(args, J, [AJ, BJ]) -> true ; err(invalid_rule, "cmp necesita args con dos términos")),
        parse_term(AJ, A), parse_term(BJ, B), Item = cmp(Op, A, B),
        (   memberchk(Op, ["=", "!="]) ; \+ (member(c(X), [A, B]), \+ number(X))
        ->  true
        ;   err(invalid_rule, "~s sólo compara números; una constante no numérica nunca se cumpliría", [Op])
        )
    ;   v3, get_dict(agg, J, Op)
    ->  parse_agg(J, Op, Item)
    ;   v3, get_dict(op, J, Op)
    ->  parse_op(J, Op, Item)
    ;   parse_lit(J, [pred, args, not], "literal", Lit), bool_opt(J, not, Not),
        (Not == true -> Item = neg(Lit) ; Item = pos(Lit))
    ).
cmp_op(Op) :- memberchk(Op, ["=", "!=", "<", "<=", ">", ">="]).
agg_op(Op) :- memberchk(Op, ["count", "sum", "min", "max"]).
arith_op(Op) :- memberchk(Op, ["+", "-", "*", "/"]).

parse_agg(J, Op, agg(Op, Lit, Val, As)) :-
    check_keys(J, [agg, pred, args, value, as], "agregado"),
    (agg_op(Op) -> true ; err(invalid_rule, "agg admite count, sum, min y max")),
    dict_pairs(J, _, Pairs), include([K-_]>>memberchk(K, [pred, args]), Pairs, LP), dict_pairs(LJ, _, LP),
    parse_lit(LJ, [pred, args], "agregado", Lit),
    new_var(J, as, "as del agregado", As),
    named_vars(Lit, LV),
    (   Op == "count"
    ->  (get_dict(value, J, _) -> err(invalid_rule, "count no lleva value: cuenta tuplas") ; Val = none)
    ;   (get_dict(value, J, VJ) -> true ; err(invalid_rule, "~s necesita value: la variable que se agrega", [Op])),
        parse_term(VJ, Val),
        (Val = v(N), N \== "_", memberchk(N, LV) -> true ; err(invalid_rule, "value debe ser una variable del literal agregado"))
    ),
    As = v(AN), (memberchk(AN, LV) -> err(unsafe_rule, "as del agregado no puede aparecer en su propio literal") ; true).

parse_op(J, Op, op(Op, A, B, As)) :-
    check_keys(J, [op, args, as], "operación"),
    (arith_op(Op) -> true ; err(invalid_rule, "op admite + - * /")),
    (get_dict(args, J, [AJ, BJ]) -> true ; err(invalid_rule, "op necesita args con dos términos")),
    parse_term(AJ, A), parse_term(BJ, B),
    (\+ (member(c(X), [A, B]), \+ number(X)) -> true ; err(invalid_rule, "op sólo opera con números")),
    new_var(J, as, "as de la operación", As).

new_var(J, K, What, V) :-
    (get_dict(K, J, VJ) -> parse_term(VJ, V) ; err(invalid_rule, "Falta ~s", [What])),
    (V = v(N), N \== "_" -> true ; err(invalid_rule, "~s debe ser una variable ?Nombre", [What])).

parse_lit(J, Keys, Where, lit(P, Ts)) :-
    check_keys(J, Keys, Where),
    (get_dict(pred, J, P), pred_string(P) -> true ; err(invalid_literal, "~s necesita pred: texto de 1 a 128 caracteres", [Where])),
    (get_dict(args, J, AJ) -> true ; AJ = []),
    (is_list(AJ), length(AJ, N), N =< 32 -> true ; err(invalid_literal, "args de ~s debe ser una lista de hasta 32 términos", [P])),
    maplist(parse_term, AJ, Ts).

parse_term(V, T) :-
    (   string(V), sub_string(V, 0, 2, _, "??")
    ->  sub_string(V, 1, _, 0, C), T = c(C)
    ;   string(V), sub_string(V, 0, 1, _, "?")
    ->  sub_string(V, 1, _, 0, Name),
        (var_name(Name) -> T = v(Name) ; err(invalid_term, "Variable inválida ~s; usá ?Nombre o ?_", [V]))
    ;   (string(V) ; number(V) ; V == true ; V == false)
    ->  T = c(V)
    ;   err(invalid_term, "Los términos son texto, número o booleano")
    ).
var_name(N) :- string(N), string_length(N, L), between(1, 64, L), string_codes(N, Cs), forall(member(C, Cs), code_type(C, csym)).
pred_string(P) :- string(P), string_length(P, L), between(1, 128, L).
id_string(Id) :- (string(Id), string_length(Id, L), between(1, 128, L) -> true ; err(invalid_request, "Los id son texto de 1 a 128 caracteres")).

% Forma de los términos leídos del almacén (el archivo podría haberse editado a mano).
% El formato 1 sólo tiene los elementos del contrato 2.
valid_fact(P, Vs) :- pred_string(P), is_list(Vs), maplist(valid_value, Vs).
valid_rule(F, rule(Id, Head, Body)) :- string(Id), valid_lit(Head), is_list(Body), maplist(valid_body(F), Body).
valid_constraint(F, constraint(Id, M, Body)) :- string(Id), string(M), is_list(Body), Body \== [], maplist(valid_body(F), Body).
valid_body(_, pos(L)) :- valid_lit(L).
valid_body(_, neg(L)) :- valid_lit(L).
valid_body(_, cmp(Op, A, B)) :- cmp_op(Op), valid_term(A), valid_term(B).
valid_body(2, agg(Op, L, Val, v(As))) :-
    agg_op(Op), valid_lit(L), var_name(As), As \== "_", named_vars(L, LV), \+ memberchk(As, LV),
    (Op == "count" -> Val == none ; Val = v(N), N \== "_", memberchk(N, LV)).
valid_body(2, op(Op, A, B, v(As))) :-
    arith_op(Op), valid_term(A), valid_term(B), var_name(As), As \== "_", \+ (member(c(X), [A, B]), \+ number(X)).
valid_lit(lit(P, Ts)) :- pred_string(P), is_list(Ts), maplist(valid_term, Ts).
valid_term(v(N)) :- var_name(N).
valid_term(c(V)) :- valid_value(V).
valid_value(V) :- (string(V) ; number(V) ; V == true ; V == false), !.

% Seguridad (range restriction): toda variable de la cabeza, de una negación o de una
% comparación queda ligada por un literal positivo o, en el contrato 3, por un agregado o
% una op; ?_ sólo dentro de literales del cuerpo.
check_rule(rule(Id, lit(_, HA), Body)) :-
    (memberchk(v("_"), HA) -> err(unsafe_rule, "La regla ~s usa ?_ en la cabeza", [Id]) ; true),
    bound_vars(Id, HA, Body, Bound), named_vars(HA, HV),
    (   subset(HV, Bound) -> true
    ;   v3 -> err(unsafe_rule, "La regla ~s tiene variables de cabeza sin ligar por literales positivos, agregados u op", [Id])
    ;   err(unsafe_rule, "La regla ~s tiene variables de cabeza fuera de literales positivos", [Id])
    ),
    check_filters(Id, Body, Bound).
check_constraint(constraint(Id, _, Body)) :- bound_vars(Id, [], Body, Bound), check_filters(Id, Body, Bound).
check_filters(Id, Body, PV) :-
    forall(member(neg(L), Body), (named_vars(L, V), subset(V, PV) -> true
        ; err(unsafe_rule, "~s niega con variables no ligadas por un literal positivo", [Id]))),
    forall(member(cmp(_, A, B), Body), (\+ memberchk(v("_"), [A, B]), named_vars([A, B], V), subset(V, PV) -> true
        ; err(unsafe_rule, "~s compara variables no ligadas por un literal positivo", [Id]))),
    forall(member(op(_, A, B, _), Body), (\+ memberchk(v("_"), [A, B]) -> true
        ; err(unsafe_rule, "~s opera con ?_; los argumentos de op deben estar ligados", [Id]))).
positive_vars(Body, PV) :- findall(L, member(pos(L), Body), Ls), named_vars(Ls, PV).
named_vars(T, Names) :- findall(N, (sub_term(S, T), nonvar(S), S = v(N), N \== "_"), Ns), sort(Ns, Names).

% Variables ligadas: las de literales positivos, las que liga cada agregado (grupo y as) y
% los as de cada op. Ninguna la liga dos veces un agregado o una op, y las op no forman ciclos.
bound_vars(Id, HA, Body, Bound) :-
    positive_vars(Body, PV),
    findall(G, (member(I, Body), item_io(HA, Body, PV, I, _, G), G \== []), Gs),
    append(Gs, All), msort(All, Sorted),
    (append(_, [X, X|_], Sorted) -> err(unsafe_rule, "En ~s la variable ?~s la ligan dos agregados u op", [Id, X]) ; true),
    (member(N, All), memberchk(N, PV) -> err(unsafe_rule, "En ~s el as ?~s ya lo liga un literal positivo", [Id, N]) ; true),
    findall(G, (member(I, Body), I = agg(_, _, _, _), item_io(HA, Body, PV, I, _, G)), AGs),
    append([PV|AGs], B0L), sort(B0L, B0),
    findall(Needs-Gives, (member(I, Body), I = op(_, _, _, _), item_io(HA, Body, PV, I, Needs, Gives)), Ops),
    close_ops(Ops, B0, Bound, Left),
    (Left == [] -> true ; err(unsafe_rule, "~s opera con variables sin ligar", [Id])).
close_ops(Ops, B0, B, Left) :-
    partition([Ns-_]>>ord_subset(Ns, B0), Ops, Ready, Rest),
    (   Ready == []
    ->  B = B0, Left = Rest
    ;   foldl([_-G, X0, X]>>(ord_union(X0, G, X)), Ready, B0, B1), close_ops(Rest, B1, B, Left)
    ).

% Necesita y liga, por elemento no positivo. En un agregado, las variables de su literal que
% también están en literales positivos son externas (necesita); las que aparecen en otra
% parte de la regla son de grupo (las liga); el resto son locales.
item_io(_, _, _, neg(L), Needs, []) :- named_vars(L, Needs).
item_io(_, _, _, cmp(_, A, B), Needs, []) :- named_vars([A, B], Needs).
item_io(_, _, _, op(_, A, B, v(As)), Needs, [As]) :- named_vars([A, B], Needs).
item_io(HA, Body, PV, agg(Op, L, Val, v(As)), Outer, Gives) :-
    named_vars(L, LV), ord_intersection(LV, PV, Outer), ord_subtract(LV, PV, Free),
    selectchk(agg(Op, L, Val, v(As)), Body, Others), named_vars(HA-Others, Elsewhere),
    ord_intersection(Free, Elsewhere, Group), ord_union(Group, [As], Gives).
item_io(_, _, _, pos(_), [], []).

parse_query(Idx, J, query(Idx, Lit)) :- parse_lit(J, [pred, args], "query", Lit).

%% Evaluación bottom-up semi-ingenua por estratos
% Cada pred/aridad es un predicado dinámico propio en el módulo kb con dos argumentos
% extra: generación y justificación. Así SWI indexa por cualquier argumento.
% Justificación: base(given|stored, Fuentes) o rule(Id, Premisas).

solve_program(Program, Queries, Settings, Result) :-
    Seconds = Settings.seconds, Inferences is Seconds * 10000000,
    call_with_time_limit(Seconds,
        call_with_inference_limit(once(solve_(Program, Queries, Settings, Result)), Inferences, R)),
    (R == inference_limit_exceeded -> err(inference_limit, "Se excedió el límite de inferencias") ; true).

solve_(program(Facts, Rules, Constraints), Queries, Settings, result(Answers, Violations, Stats)) :-
    reset,
    stratify(Rules, Strata, MaxS),
    forall(member(fact(P, Vs, S)-Origin, Facts),
        (length(Vs, L), ensure_pred(P/L), add_fact(P/L, Vs, 0, base(Origin, S)))),
    flag(total, Base, Base),
    maplist(compile_rule(Strata), Rules),
    eval_strata(0, MaxS, 1, Iterations),
    maplist(answer(Settings), Queries, Answers),
    maplist(compile_constraint, Constraints, Compiled),
    foldl(violation(Settings), Compiled, Violations, []),
    flag(total, Total, Total), Derived is Total - Base, Strata1 is MaxS + 1,
    Stats = _{facts:Total, derived:Derived, strata:Strata1, iterations:Iterations}.

reset :-
    forall(pred_name(_, Name/A), (functor(H, Name, A), retractall(kb:H))),
    retractall(pred_name(_, _)), retractall(rplan(_, _, _, _, _)), retractall(rule_def(_, _)),
    retractall(smemo(_, _, _)), flag(total, _, 0).

ensure_pred(Key) :-
    (   pred_name(Key, _)
    ->  true
    ;   flag(preds, N, N + 1), atom_concat(p_, N, Name), Key = _/L, A is L + 2,
        dynamic(kb:Name/A), assertz(pred_name(Key, Name/A))
    ).
pred_goal(Key, Args, Gen, Why, kb:H) :- pred_name(Key, Name/_), append(Args, [Gen, Why], All), H =.. [Name|All].
match(Key, Args, Gen) :- pred_goal(Key, Args, Gen, _, G), call(G).
fact_why(Key, Args, Why) :- pred_goal(Key, Args, _, Why, G), once(G).

add_fact(Key, Args, Gen, Why) :-
    (   match(Key, Args, _)
    ->  true
    ;   pred_goal(Key, Args, Gen, Why, kb:H), assertz(kb:H),
        flag(total, T, T + 1), flag(new_facts, N, N + 1)
    ).

% Estrato(cabeza) >= estrato(positivo) y > estrato(negado o agregado). Una regla con agregado
% u op no es recursiva: su cabeza queda por encima de todo su cuerpo. Si algún estrato supera
% la cantidad de predicados hay un ciclo prohibido.
stratify(Rules, Strata, Max) :-
    findall(K, (member(rule(_, H, B), Rules), (L = H ; member(I, B), body_lit(I, L)), lit_key(L, K)), Ks0),
    sort(Ks0, Ks), length(Ks, N), pairs_keys_values(Pairs, Ks, _), maplist([_-0]>>true, Pairs),
    list_to_assoc(Pairs, A0), relax(Rules, N, A0, Strata),
    assoc_to_values(Strata, Vs), max_list([0|Vs], Max).
body_lit(pos(L), L).
body_lit(neg(L), L).
body_lit(agg(_, L, _, _), L).
relax(Rules, N, A0, A) :-
    foldl(relax_rule, Rules, A0-false, A1-Changed),
    (   Changed == false
    ->  A = A1
    ;   assoc_to_values(A1, Vs), max_list(Vs, M), M > N
    ->  (   v3
        ->  err(unstratified, "Hay recursión a través de una negación, un agregado o una op; el programa no es estratificable")
        ;   err(unstratified, "Hay recursión a través de una negación; el programa no es estratificable")
        )
    ;   relax(Rules, N, A1, A)
    ).
relax_rule(rule(_, H, Body), A0-C0, A-C) :-
    lit_key(H, HK), get_assoc(HK, A0, Cur),
    (member(I, Body), (I = agg(_, _, _, _) ; I = op(_, _, _, _)) -> Step = 1 ; Step = 0),
    foldl(need(A0, Step), Body, Cur, Need),
    (Need > Cur -> put_assoc(HK, A0, Need, A), C = true ; A = A0, C = C0).
need(A, Step, pos(L), M0, M) :- !, lit_key(L, K), get_assoc(K, A, S), M is max(M0, S + Step).
need(A, _, neg(L), M0, M) :- !, lit_key(L, K), get_assoc(K, A, S), M is max(M0, S + 1).
need(A, _, agg(_, L, _, _), M0, M) :- !, lit_key(L, K), get_assoc(K, A, S), M is max(M0, S + 1).
need(_, _, _, M, M).
lit_key(lit(P, As), P/L) :- length(As, L).

% Un plan "naive" y uno "delta(J)" por cada literal positivo recursivo del mismo estrato,
% con ese literal primero. Los demás elementos van apenas tienen ligado lo que necesitan.
compile_rule(Strata, rule(Id, Head, Body)) :-
    lit_key(Head, HK), get_assoc(HK, Strata, S), Head = lit(_, HA),
    forall((member(I, Body), body_lit(I, L)), (lit_key(L, K), ensure_pred(K))),
    ensure_pred(HK),
    numbered_body(HA, Body, Pos, Filters),
    plan(Pos, Filters, Naive), to_vars(HK-HA-Naive, PH-PA-PNaive),
    assertz(rplan(S, Id, naive, PH-PA, PNaive)), assertz(rule_def(Id, Body)),
    forall(( member(J-(P-L), Pos), lit_key(L, K), get_assoc(K, Strata, S),
             selectchk(J-(P-L), Pos, Others), plan([J-(P-L)|Others], Filters, Steps),
             to_vars(HK-HA-Steps, DH-DA-DSteps) ),
           assertz(rplan(S, Id, delta(J), DH-DA, DSteps))).

% Positivos J-(Posición-Lit) numerados para la generación; el resto io(Posición, Elemento,
% Necesita, Liga). La posición en el cuerpo ordena las premisas de la prueba.
numbered_body(HA, Body, Pos, Filters) :-
    numlist_for(Body, Is), pairs_keys_values(Indexed, Is, Body),
    findall(P-L, member(P-pos(L), Indexed), Ls), numlist_for(Ls, Js), pairs_keys_values(Pos, Js, Ls),
    positive_vars(Body, PV),
    findall(io(P, I, N, G), (member(P-I, Indexed), I \= pos(_), item_io(HA, Body, PV, I, N, G)), Filters).

plan(Pos, Filters, Steps) :-
    ready_steps(Filters, [], Rest, Bound, S0), plan_(Pos, Bound, Rest, S1), append(S0, S1, Steps).
plan_([], _, _, []).
plan_([J-(P-L)|Pos], Bound0, Filters, [p(J, P, K, As)|Steps]) :-
    lit_key(L, K), L = lit(_, As), named_vars(L, V), ord_union(Bound0, V, Bound1),
    ready_steps(Filters, Bound1, Later, Bound, RS), append(RS, Steps0, Steps),
    plan_(Pos, Bound, Later, Steps0).
ready_steps(Filters, B0, Rest, B, Steps) :-
    partition([io(_, _, N, _)]>>ord_subset(N, B0), Filters, Ready, Later),
    (   Ready == []
    ->  Rest = Filters, B = B0, Steps = []
    ;   maplist(filter_step, Ready, S0), foldl([io(_, _, _, G), X0, X]>>ord_union(X0, G, X), Ready, B0, B1),
        ready_steps(Later, B1, Rest, B, S1), append(S0, S1, Steps)
    ).
filter_step(io(P, neg(L), _, _), n(P, K, As)) :- lit_key(L, K), L = lit(_, As).
filter_step(io(P, cmp(Op, A, B), _, _), c(P, Op, A, B)).
filter_step(io(P, op(Op, A, B, As), _, _), o(P, Op, A, B, As)).
filter_step(io(P, agg(Op, L, Val, As), _, Gives), a(P, Op, K, Args, Val, As, Group)) :-
    lit_key(L, K), L = lit(_, Args), As = v(AN), ord_subtract(Gives, [AN], GN),
    maplist([N, v(N)]>>true, GN, Group).

% v(Nombre) -> variable Prolog compartida; v("_") -> variable fresca; c(V) -> V.
to_vars(T, P) :- empty_assoc(M0), to_vars(T, P, M0, _).
to_vars(v("_"), _, M, M) :- !.
to_vars(v(N), V, M0, M) :- !, (get_assoc(N, M0, V) -> M = M0 ; put_assoc(N, M0, V, M)).
to_vars(c(X), X, M, M) :- !.
to_vars(T, P, M0, M) :-
    compound(T), !, compound_name_arguments(T, F, As),
    foldl([A, B, X0, X]>>to_vars(A, B, X0, X), As, Bs, M0, M), compound_name_arguments(P, F, Bs).
to_vars(T, T, M, M).

eval_strata(S, Max, K, K) :- S > Max, !.
eval_strata(S, Max, K0, K) :-
    flag(new_facts, _, 0),
    forall(rplan(S, Id, naive, H, Steps), fire(naive(K0), H, Id, Steps, K0)),
    delta_loop(S, K0, K1), S1 is S + 1, eval_strata(S1, Max, K1, K).
delta_loop(S, K, Kend) :-
    flag(new_facts, N, 0), K1 is K + 1,
    (   N =:= 0
    ->  Kend = K1
    ;   forall(rplan(S, Id, delta(J), H, Steps), fire(delta(J, K1), H, Id, Steps, K1)),
        delta_loop(S, K1, Kend)
    ).
fire(Mode, HK-HA, Id, Steps, Gen) :-
    forall(premises(Steps, Mode, Ps), add_fact(HK, HA, Gen, rule(Id, Ps))).

premises(Steps, Mode, Ps) :- run_steps(Steps, Mode, Ps0), keysort(Ps0, Ps1), pairs_values(Ps1, Ps).
run_steps([], _, []).
run_steps([p(J, P, K, As)|Ss], Mode, [P-(K-As)|Ps]) :-
    (Mode = delta(J0, K0), J =:= J0 -> G is K0 - 1 ; true),  % generación ligada: SWI indexa por ella
    match(K, As, G), gen_ok(Mode, J, G), run_steps(Ss, Mode, Ps).
run_steps([n(P, K, As)|Ss], Mode, [P-not(K-As)|Ps]) :- \+ match(K, As, _), run_steps(Ss, Mode, Ps).
run_steps([c(_, Op, A, B)|Ss], Mode, Ps) :- compare_terms(Op, A, B), run_steps(Ss, Mode, Ps).
run_steps([o(P, Op, A, B, R)|Ss], Mode, [P-op(Op, A, B, R)|Ps]) :- arith(Op, A, B, R), run_steps(Ss, Mode, Ps).
run_steps([a(P, Op, K, Args, Val, R, Group)|Ss], Mode, [P-agg(Op, K, Args, Val, R)|Ps]) :-
    aggregate(Op, K, Args, Val, Group, R), run_steps(Ss, Mode, Ps).

% Semi-ingenua: el literal delta usa sólo la generación anterior; los previos, las más
% viejas; los siguientes, todas las ya cerradas. Cada derivación nueva se ve una vez.
gen_ok(all, _, _).
gen_ok(naive(K), _, G) :- G < K.
gen_ok(delta(I, K), J, G) :- (J =:= I -> G =:= K - 1 ; J < I -> G < K - 1 ; G < K).

compare_terms("=", A, B) :- !, (number(A), number(B) -> A =:= B ; A == B).
compare_terms("!=", A, B) :- !, \+ compare_terms("=", A, B).
compare_terms(Op, A, B) :- number(A), number(B), order(Op, A, B).
order("<", A, B) :- A < B.
order("<=", A, B) :- A =< B.
order(">", A, B) :- A > B.
order(">=", A, B) :- A >= B.

% Con un argumento no numérico, dividiendo por cero, con un desborde o con un entero que no
% cabe exacto en un double (|n| > 2^53), la op no se cumple: el resultado tiene que poder
% viajar por JSON sin perder precisión y no puede crecer sin cota.
arith(Op, A, B, R) :-
    number(A), number(B), \+ (Op == "/", B =:= 0),
    catch(arith_(Op, A, B, R0), error(evaluation_error(_), _), fail), norm_num(R0, R), safe_num(R).
safe_num(R) :- (integer(R) -> abs(R) =< 9007199254740992 ; true).
arith_("+", A, B, R) :- R is A + B.
arith_("-", A, B, R) :- R is A - B.
arith_("*", A, B, R) :- R is A * B.
arith_("/", A, B, R) :- R is A / B.

% Agregado sobre un estrato cerrado. Las tuplas distintas del literal (con las externas ya
% ligadas) se agrupan por las variables de grupo; sin grupo hay un único resultado.
aggregate(Op, K, Args, Val, Group, R) :-
    findall(Group-(Args-Val), match(K, Args, _), T0), sort(T0, Tuples),
    (   Group == []
    ->  pairs_values(Tuples, Rows), agg_value(Op, Rows, R)
    ;   group_pairs_by_key(Tuples, Groups), member(Group-Rows, Groups), agg_value(Op, Rows, R)
    ).
agg_value("count", Rows, N) :- !, length(Rows, N).
agg_value(Op, Rows, R) :-
    findall(V, (member(_-V, Rows), number(V)), Vs),
    (   Op == "sum" -> catch(sum_list(Vs, R0), error(evaluation_error(_), _), fail)
    ;   Vs \== [], (Op == "min" -> min_list(Vs, R0) ; max_list(Vs, R0))
    ),
    norm_num(R0, R), safe_num(R).
% Tuplas que aportan a un agregado: todas para count; para el resto, las de valor numérico.
agg_rows(Op, K, Args, Val, Rows) :-
    findall(Args-Val, match(K, Args, _), R0), sort(R0, R1),
    (Op == "count" -> Rows = R1 ; include([_-V]>>number(V), R1, Rows)).

%% Respuestas, restricciones y pruebas

answer(Settings, query(Idx, Lit), Out) :-
    lit_key(Lit, K), ensure_pred(K), Lit = lit(P, Args0),
    empty_assoc(M0), to_vars(Args0, Args, M0, M), assoc_to_list(M, NV),
    findall(NV-Args, match(K, Args, _), Sols0), sort(1, @<, Sols0, Sols),
    results(Settings, Sols, [NV1-A1, R]>>result(Settings, K, NV1-A1, R), Count, Truncated, Rs),
    (Count > 0 -> Holds = true ; Holds = false),
    Out0 = _{query:Idx, pred:P, holds:Holds, count:Count, truncated:Truncated, results:Rs},
    (   Settings.failures == true, Holds == false
    ->  failures(K, Args0, Fs), Out = Out0.put(failures, Fs)
    ;   Out = Out0
    ).
result(Settings, K, NV-Args, R) :-
    bindings(NV, B),
    (   Settings.explain == true
    ->  proof_budget(Budget), proof(K-Args, Settings.proof_depth, Budget, _, Proof),
        R0 = _{bindings:B, proof:Proof}
    ;   R0 = _{bindings:B}
    ),
    (v3 -> support_sources([K-Args], Srcs), R = R0.put(sources, Srcs) ; R = R0).

compile_constraint(constraint(Id, Msg, Body), cons(Id, Msg, NV, Steps)) :-
    forall((member(I, Body), body_lit(I, L)), (lit_key(L, K), ensure_pred(K))),
    numbered_body([], Body, Pos, Filters),
    plan(Pos, Filters, Steps0), empty_assoc(M0), to_vars(Steps0, Steps, M0, M), assoc_to_list(M, NV0),
    % Las variables locales de un agregado no se ligan: no van en las ligaduras.
    bound_vars(Id, [], Body, Bound), include([N-_]>>memberchk(N, Bound), NV0, NV).
violation(Settings, cons(Id, Msg, NV, Steps), V0, V) :-
    findall(NV-Ps, premises(Steps, all, Ps), Sols0), sort(1, @<, Sols0, Sols),
    (   Sols == []
    ->  V0 = V
    ;   results(Settings, Sols, [NV1-Ps1, R]>>violation_result(Settings, NV1-Ps1, R), Count, Truncated, Rs),
        V0 = [_{constraint:Id, message:Msg, count:Count, truncated:Truncated, results:Rs}|V]
    ).
violation_result(Settings, NV-Ps, R) :-
    bindings(NV, B),
    (   Settings.explain == true
    ->  proof_budget(Budget), D is Settings.proof_depth - 1,
        foldl(premise(D), Ps, Js, Budget, _), R0 = _{bindings:B, premises:Js}
    ;   R0 = _{bindings:B}
    ),
    (v3 -> support_sources(Ps, Srcs), R = R0.put(sources, Srcs) ; R = R0).

results(Settings, Sols, Map, Count, Truncated, Rs) :-
    length(Sols, Count), Max = Settings.max_results,
    (Count > Max -> length(Taken, Max), append(Taken, _, Sols), Truncated = true ; Taken = Sols, Truncated = false),
    maplist(Map, Taken, Rs).

bindings(NV, B) :- findall(A-V, (member(N-V, NV), atom_string(A, N)), Pairs), dict_pairs(B, _, Pairs).

proof(K-Args, Depth, B0, B, J) :-
    lit_json(K, Args, LJ),
    (   B0 =< 0
    ->  J = _{fact:LJ, by:truncated}, B = B0
    ;   B1 is B0 - 1, fact_why(K, Args, Why),
        (   Why = rule(Id, Ps)
        ->  (   Depth =< 0
            ->  J = _{fact:LJ, by:truncated}, B = B1
            ;   D1 is Depth - 1, foldl(premise(D1), Ps, Js, B1, B),
                J = _{fact:LJ, by:rule, rule:Id, premises:Js}
            )
        ;   Why = base(Origin, Srcs),
            (v3 -> J = _{fact:LJ, by:Origin, sources:Srcs} ; J = _{fact:LJ, by:Origin}), B = B1
        )
    ).
premise(_, not(K-As), _{not:LJ}, B, B) :- !, lit_json(K, As, LJ).
premise(_, op(Op, X, Y, R), _{op:Op, args:[X, Y], result:R}, B, B) :- !.
premise(D, agg(Op, K, Args, Val, R), J, B0, B) :- !,
    agg_rows(Op, K, Args, Val, Rows), agg_items(Max), length(Rows, N),
    (N > Max -> length(Taken, Max), append(Taken, _, Rows), T = true ; Taken = Rows, T = false),
    foldl([A-_, PJ, X0, X]>>proof(K-A, D, X0, X, PJ), Taken, Items, B0, B),
    lit_json(K, Args, OJ),
    J = _{agg:Op, of:OJ, result:R, items:Items, truncated:T}.
premise(D, K-As, J, B0, B) :- proof(K-As, D, B0, B, J).

% Fuentes de todos los hechos de base de los que depende una lista de premisas, recorriendo la
% derivación completa (no la prueba recortada). Las de cada hecho se calculan una vez por
% consulta y se reusan entre resultados (smemo, indexado por term_hash).
support_sources(Ps, Srcs) :- foldl(premise_sources, Ps, [], Srcs).
premise_sources(not(_), S, S) :- !.
premise_sources(op(_, _, _, _), S, S) :- !.
premise_sources(agg(Op, K, Args, Val, _), S0, S) :- !,
    agg_rows(Op, K, Args, Val, Rows),
    foldl([X-_, A0, A]>>(fact_sources(K, X, T), ord_union(A0, T, A)), Rows, S0, S).
premise_sources(K-Args, S0, S) :- fact_sources(K, Args, T), ord_union(S0, T, S).
fact_sources(K, Args, S) :-
    term_hash(K-Args, H),
    (   smemo(H, K-Args, S0)
    ->  S = S0
    ;   fact_why(K, Args, Why),
        (Why = rule(_, Ps) -> support_sources(Ps, S) ; Why = base(_, S)),
        assertz(smemo(H, K-Args, S))
    ).

% Explicación de fallos: para cada regla cuya cabeza unifica con la query, el primer elemento
% del cuerpo (en el orden del plan) sin solución con lo anterior ligado.
failures(K, Args0, Fs) :-
    findall(F, (rplan(_, Id, naive, K-HA, Steps), rule_failure(Id, HA, Steps, Args0, F)), Fs0),
    sort(rule, @<, Fs0, Fs).
rule_failure(Id, HA, Steps, Args0, _{rule:Id, position:P, item:IJ}) :-
    to_vars(Args0, QA), HA = QA,
    first_failing(Steps, [], P), rule_def(Id, Body), nth1(P, Body, Item), body_json(Item, IJ).
first_failing([S|Ss], Prefix0, P) :-
    append(Prefix0, [S], Prefix),
    (   \+ \+ run_steps(Prefix, all, _)
    ->  first_failing(Ss, Prefix, P)
    ;   step_position(S, P)
    ).
step_position(p(_, P, _, _), P).
step_position(n(P, _, _), P).
step_position(c(P, _, _, _), P).
step_position(o(P, _, _, _, _), P).
step_position(a(P, _, _, _, _, _, _), P).

lit_json(P/_, Args, _{pred:P, args:Vs}) :- maplist([A, V]>>(var(A) -> V = "?_" ; V = A), Args, Vs).

%% Exportación: términos internos -> JSON del contrato
% Un hecho por fuente, así lo exportado se puede volver a asertar tal cual.

fact_json(fact(P, Vs, Srcs), J0, J) :-
    maplist([V, X]>>term_json(c(V), X), Vs, Js),
    (   Srcs == []
    ->  J0 = [_{pred:P, args:Js}|J]
    ;   foldl([S, [_{pred:P, args:Js, source:S}|T], T]>>true, Srcs, J0, J)
    ).
rule_json(rule(Id, Head, Body), _{id:Id, head:HJ, body:BJ}) :- lit_out(Head, HJ), maplist(body_json, Body, BJ).
constraint_json(constraint(Id, M, Body), _{id:Id, message:M, body:BJ}) :- maplist(body_json, Body, BJ).
body_json(pos(L), J) :- lit_out(L, J).
body_json(neg(L), J) :- lit_out(L, J0), J = J0.put(not, true).
body_json(cmp(Op, A, B), _{cmp:Op, args:[AJ, BJ]}) :- term_json(A, AJ), term_json(B, BJ).
body_json(op(Op, A, B, As), _{op:Op, args:[AJ, BJ], as:SJ}) :- term_json(A, AJ), term_json(B, BJ), term_json(As, SJ).
body_json(agg(Op, lit(P, Ts), Val, As), J) :-
    maplist(term_json, Ts, Js), term_json(As, SJ), J0 = _{agg:Op, pred:P, args:Js, as:SJ},
    (Val == none -> J = J0 ; term_json(Val, VJ), J = J0.put(value, VJ)).
lit_out(lit(P, Ts), _{pred:P, args:Js}) :- maplist(term_json, Ts, Js).
term_json(v(N), J) :- string_concat("?", N, J).
term_json(c(V), J) :- (string(V), sub_string(V, 0, 1, _, "?") -> string_concat("?", V, J) ; J = V).

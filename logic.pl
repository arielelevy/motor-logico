:- module(logic, [logic_request/2]).
:- use_module(library(assoc)).
:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(occurs)).
:- use_module(library(pairs)).
:- use_module(library(time)).
:- use_module(store).

% Contrato 2, dominio logic: Datalog estratificado con negación, comparaciones,
% restricciones de integridad, pruebas y almacenes persistentes opcionales.
% Las reglas llegan como datos y se interpretan contra hechos propios: nunca se
% llama a un goal recibido ni se consulta código del cliente o del almacén.

:- dynamic pred_name/2, rplan/5.

err(Code, Message) :- throw(motor_error(Code, Message)).
err(Code, Format, Args) :- format(string(M), Format, Args), throw(motor_error(Code, M)).

limit(seconds, 5, 1, 30).
limit(max_results, 100, 1, 10000).
limit(proof_depth, 12, 1, 64).
max_items(facts, 100000).
max_items(rules, 5000).
max_items(constraints, 1000).
max_items(queries, 100).
proof_budget(300).

%% Solicitud

logic_request(In0, Out) :-
    normalize(In0, In),
    check_keys(In, [contract, domain, store, expect_revision, assert, retract, facts, rules,
                    constraints, queries, explain, export, limits], "la consulta"),
    (get_dict(domain, In, "logic") -> true ; err(unsupported_domain, "El contrato 2 sólo admite domain \"logic\"")),
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
            (Changed == true -> store_save(Name, S1) ; true),
            store_out(Name, S1, Changed, Export, StoreOut)))
    ),
    Result = result(Answers, Violations, Stats),
    (Violations == [] -> Consistent = true ; Consistent = false),
    Out = _{contract:2, domain:logic, store:StoreOut, answers:Answers,
            consistent:Consistent, violations:Violations, stats:Stats}.

% Toda la entrada: junta pares surrogate (json_read los deja separados y no se podrían
% volver a leer del almacén), rechaza los sueltos y lleva 1.0 a 1 y -0.0 a 0.
normalize(D, N) :- is_dict(D), !, dict_pairs(D, T, P0), maplist([K-V, K-W]>>normalize(V, W), P0, P), dict_pairs(N, T, P).
normalize(L, N) :- is_list(L), !, maplist(normalize, L, N).
normalize(S, N) :- string(S), !, string_codes(S, C0), surrogates(C0, C), string_codes(N, C).
normalize(F, N) :- float(F), F =:= truncate(F), abs(F) < 9007199254740992, !, N is truncate(F).
normalize(X, X).
surrogates([], []).
surrogates([H, L|T], [C|R]) :- between(0xD800, 0xDBFF, H), between(0xDC00, 0xDFFF, L), !,
    C is 0x10000 + ((H - 0xD800) << 10) + (L - 0xDC00), surrogates(T, R).
surrogates([C|_], _) :- between(0xD800, 0xDFFF, C), !, err(invalid_term, "Texto con un surrogate UTF-16 suelto").
surrogates([C|T], [C|R]) :- surrogates(T, R).

numlist_for(L, Idx) :- length(L, N), (N =:= 0 -> Idx = [] ; numlist(1, N, Idx)).

settings(In, _{explain:E, seconds:S, max_results:M, proof_depth:D}) :-
    bool_opt(In, explain, E),
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
        items(R, facts, DFJ), maplist(parse_fact, DFJ, DF),
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

load(Name, store(Rev, Facts, Rules, Constraints)) :-
    store_load(Name, store(Rev, Facts, Rules, Constraints)),
    (   maplist(valid_fact, Facts), maplist(valid_rule, Rules), maplist(valid_constraint, Constraints)
    ->  true
    ;   err(corrupt_store, "El almacén ~s contiene términos con forma inválida", [Name])
    ),
    maplist(check_rule, Rules), maplist(check_constraint, Constraints).

apply_changes(changes(AF, AR, AC, DF, DR, DC), store(Rev, F0, R0, C0), store(Rev1, F, R, C), Changed) :-
    sort(DF, DFs), sort(AF, AFs), ord_subtract(F0, DFs, F1), ord_union(F1, AFs, F),
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
    ->  maplist(fact_json, F, FJ), maplist(rule_json, R, RJ), maplist(constraint_json, C, CJ),
        Out = Out0.put(content, _{facts:FJ, rules:RJ, constraints:CJ})
    ;   Out = Out0
    ).

solve_with(store(_, SF, SR, SC), program(LF, LR, LC), Queries, Settings, Result) :-
    maplist(arg(1), SR, SRI), maplist(arg(1), LR, LRI), append(SRI, LRI, RI),
    maplist(arg(1), SC, SCI), maplist(arg(1), LC, LCI), append(SCI, LCI, CI),
    unique_ids(RI, "regla"), unique_ids(CI, "restricción"),
    maplist([F, F-stored]>>true, SF, SFO), maplist([F, F-given]>>true, LF, LFO),
    append(SFO, LFO, Facts), append(SR, LR, Rules), append(SC, LC, Constraints),
    solve_program(program(Facts, Rules, Constraints), Queries, Settings, Result).
solve(program(LF, LR, LC), Queries, Settings, Result) :-
    solve_with(store(0, [], [], []), program(LF, LR, LC), Queries, Settings, Result).

unique_ids(Ids, What) :-
    msort(Ids, Sorted),
    (append(_, [X, X|_], Sorted) -> err(duplicate_id, "Id de ~s repetido: ~s", [What, X]) ; true).

%% Parseo: JSON -> términos internos (sólo datos)
% Términos: v(Nombre) variable ("?X"; "?_" anónima), c(Valor) constante.
% "??x" es la constante "?x". Literales: lit(Pred, Args).
% Cuerpo: pos(Lit), neg(Lit), cmp(Op, A, B).

parse_fact(J, fact(P, Vs)) :-
    parse_lit(J, [pred, args], "hecho", lit(P, Ts)),
    maplist(fact_value(P), Ts, Vs).
fact_value(_, c(V), V) :- !.
fact_value(P, _, _) :- err(invalid_fact, "El hecho ~s tiene variables; los hechos son ground", [P]).

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
    ;   parse_lit(J, [pred, args, not], "literal", Lit), bool_opt(J, not, Not),
        (Not == true -> Item = neg(Lit) ; Item = pos(Lit))
    ).
cmp_op(Op) :- memberchk(Op, ["=", "!=", "<", "<=", ">", ">="]).

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
valid_fact(fact(P, Vs)) :- pred_string(P), is_list(Vs), maplist(valid_value, Vs).
valid_rule(rule(Id, Head, Body)) :- string(Id), valid_lit(Head), is_list(Body), maplist(valid_body, Body).
valid_constraint(constraint(Id, M, Body)) :- string(Id), string(M), is_list(Body), Body \== [], maplist(valid_body, Body).
valid_body(pos(L)) :- valid_lit(L).
valid_body(neg(L)) :- valid_lit(L).
valid_body(cmp(Op, A, B)) :- cmp_op(Op), valid_term(A), valid_term(B).
valid_lit(lit(P, Ts)) :- pred_string(P), is_list(Ts), maplist(valid_term, Ts).
valid_term(v(N)) :- var_name(N).
valid_term(c(V)) :- valid_value(V).
valid_value(V) :- (string(V) ; number(V) ; V == true ; V == false), !.

% Seguridad (range restriction): toda variable de la cabeza, de una negación o de una
% comparación aparece en un literal positivo; ?_ sólo dentro de literales del cuerpo.
check_rule(rule(Id, lit(_, HA), Body)) :-
    (memberchk(v("_"), HA) -> err(unsafe_rule, "La regla ~s usa ?_ en la cabeza", [Id]) ; true),
    positive_vars(Body, PV), named_vars(HA, HV),
    (subset(HV, PV) -> true ; err(unsafe_rule, "La regla ~s tiene variables de cabeza fuera de literales positivos", [Id])),
    check_filters(Id, Body, PV).
check_constraint(constraint(Id, _, Body)) :- positive_vars(Body, PV), check_filters(Id, Body, PV).
check_filters(Id, Body, PV) :-
    forall(member(neg(L), Body), (named_vars(L, V), subset(V, PV) -> true
        ; err(unsafe_rule, "~s niega con variables no ligadas por un literal positivo", [Id]))),
    forall(member(cmp(_, A, B), Body), (\+ memberchk(v("_"), [A, B]), named_vars([A, B], V), subset(V, PV) -> true
        ; err(unsafe_rule, "~s compara variables no ligadas por un literal positivo", [Id]))).
positive_vars(Body, PV) :- findall(L, member(pos(L), Body), Ls), named_vars(Ls, PV).
named_vars(T, Names) :- findall(N, (sub_term(S, T), nonvar(S), S = v(N), N \== "_"), Ns), sort(Ns, Names).

parse_query(Idx, J, query(Idx, Lit)) :- parse_lit(J, [pred, args], "query", Lit).

%% Evaluación bottom-up semi-ingenua por estratos
% Cada pred/aridad es un predicado dinámico propio en el módulo kb con dos argumentos
% extra: generación y justificación. Así SWI indexa por cualquier argumento.

solve_program(Program, Queries, Settings, Result) :-
    Seconds = Settings.seconds, Inferences is Seconds * 10000000,
    call_with_time_limit(Seconds,
        call_with_inference_limit(once(solve_(Program, Queries, Settings, Result)), Inferences, R)),
    (R == inference_limit_exceeded -> err(inference_limit, "Se excedió el límite de inferencias") ; true).

solve_(program(Facts, Rules, Constraints), Queries, Settings, result(Answers, Violations, Stats)) :-
    reset,
    stratify(Rules, Strata, MaxS),
    forall(member(fact(P, Vs)-Origin, Facts), (length(Vs, L), ensure_pred(P/L), add_fact(P/L, Vs, 0, Origin))),
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
    retractall(pred_name(_, _)), retractall(rplan(_, _, _, _, _)), flag(total, _, 0).

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

% Estrato(cabeza) >= estrato(positivo) y > estrato(negado). Si algún estrato supera la
% cantidad de predicados hay un ciclo a través de una negación.
stratify(Rules, Strata, Max) :-
    findall(K, (member(rule(_, H, B), Rules), (L = H ; member(pos(L), B) ; member(neg(L), B)), lit_key(L, K)), Ks0),
    sort(Ks0, Ks), length(Ks, N), pairs_keys_values(Pairs, Ks, _), maplist([_-0]>>true, Pairs),
    list_to_assoc(Pairs, A0), relax(Rules, N, A0, Strata),
    assoc_to_values(Strata, Vs), max_list([0|Vs], Max).
relax(Rules, N, A0, A) :-
    foldl(relax_rule, Rules, A0-false, A1-Changed),
    (   Changed == false
    ->  A = A1
    ;   assoc_to_values(A1, Vs), max_list(Vs, M), M > N
    ->  err(unstratified, "Hay recursión a través de una negación; el programa no es estratificable")
    ;   relax(Rules, N, A1, A)
    ).
relax_rule(rule(_, H, Body), A0-C0, A-C) :-
    lit_key(H, HK), get_assoc(HK, A0, Cur), foldl(need(A0), Body, Cur, Need),
    (Need > Cur -> put_assoc(HK, A0, Need, A), C = true ; A = A0, C = C0).
need(A, pos(L), M0, M) :- !, lit_key(L, K), get_assoc(K, A, S), M is max(M0, S).
need(A, neg(L), M0, M) :- !, lit_key(L, K), get_assoc(K, A, S), M is max(M0, S + 1).
need(_, _, M, M).
lit_key(lit(P, As), P/L) :- length(As, L).

% Un plan "naive" y uno "delta(J)" por cada literal positivo recursivo del mismo estrato,
% con ese literal primero. Los filtros (negación, comparación) van apenas sus variables
% quedan ligadas.
compile_rule(Strata, rule(Id, Head, Body)) :-
    lit_key(Head, HK), get_assoc(HK, Strata, S), Head = lit(_, HA),
    forall((member(I, Body), I \= cmp(_, _, _)), (arg(1, I, L), lit_key(L, K), ensure_pred(K))),
    ensure_pred(HK),
    numbered_body(Body, Pos, Filters),
    plan(Pos, Filters, Naive), to_vars(HK-HA-Naive, PH-PA-PNaive),
    assertz(rplan(S, Id, naive, PH-PA, PNaive)),
    forall(( member(J-(P-L), Pos), lit_key(L, K), get_assoc(K, Strata, S),
             selectchk(J-(P-L), Pos, Others), plan([J-(P-L)|Others], Filters, Steps),
             to_vars(HK-HA-Steps, DH-DA-DSteps) ),
           assertz(rplan(S, Id, delta(J), DH-DA, DSteps))).

% Positivos J-(Posición-Lit) numerados para la generación; filtros Posición-Filtro.
% La posición en el cuerpo ordena las premisas de la prueba, sea cual sea el plan.
numbered_body(Body, Pos, Filters) :-
    numlist_for(Body, Is), pairs_keys_values(Indexed, Is, Body),
    findall(P-L, member(P-pos(L), Indexed), Ls), numlist_for(Ls, Js), pairs_keys_values(Pos, Js, Ls),
    exclude([_-X]>>(X = pos(_)), Indexed, Filters).

plan(Pos, Filters, Steps) :-
    partition([F]>>(named_vars(F, [])), Filters, Ground, Rest),
    maplist(filter_step, Ground, G0),
    plan_(Pos, [], Rest, Steps0), append(G0, Steps0, Steps).
plan_([], _, _, []).
plan_([J-(P-L)|Pos], Bound0, Filters, [p(J, P, K, As)|Steps]) :-
    lit_key(L, K), L = lit(_, As), named_vars(L, V), ord_union(Bound0, V, Bound),
    partition([F]>>(named_vars(F, FV), ord_subset(FV, Bound)), Filters, Ready, Later),
    maplist(filter_step, Ready, RS), append(RS, Steps0, Steps),
    plan_(Pos, Bound, Later, Steps0).
filter_step(P-neg(L), n(P, K, As)) :- lit_key(L, K), L = lit(_, As).
filter_step(_-cmp(Op, A, B), c(Op, A, B)).

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
run_steps([c(Op, A, B)|Ss], Mode, Ps) :- compare_terms(Op, A, B), run_steps(Ss, Mode, Ps).

% Semi-ingenua: el literal delta usa sólo la generación anterior; los previos, las más
% viejas; los siguientes, todas las ya cerradas. Cada derivación nueva se ve una vez.
gen_ok(all, _, _).
gen_ok(naive(K), _, G) :- G < K.
gen_ok(delta(I, K), J, G) :- (J =:= I -> G =:= K - 1 ; J < I -> G < K - 1 ; G < K).

compare_terms("=", A, B) :- !, (number(A), number(B) -> A =:= B ; A == B).
compare_terms("!=", A, B) :- !, \+ compare_terms("=", A, B).
compare_terms(Op, A, B) :- number(A), number(B), arith(Op, A, B).
arith("<", A, B) :- A < B.
arith("<=", A, B) :- A =< B.
arith(">", A, B) :- A > B.
arith(">=", A, B) :- A >= B.

%% Respuestas, restricciones y pruebas

answer(Settings, query(Idx, Lit), Out) :-
    lit_key(Lit, K), ensure_pred(K), Lit = lit(P, Args0),
    empty_assoc(M0), to_vars(Args0, Args, M0, M), assoc_to_list(M, NV),
    findall(NV-Args, match(K, Args, _), Sols0), sort(1, @<, Sols0, Sols),
    results(Settings, Sols, [NV1-A1, R]>>result(Settings, K, NV1-A1, R), Count, Truncated, Rs),
    (Count > 0 -> Holds = true ; Holds = false),
    Out = _{query:Idx, pred:P, holds:Holds, count:Count, truncated:Truncated, results:Rs}.
result(Settings, K, NV-Args, R) :-
    bindings(NV, B),
    (   Settings.explain == true
    ->  proof_budget(Budget), proof(K-Args, Settings.proof_depth, Budget, _, Proof),
        R = _{bindings:B, proof:Proof}
    ;   R = _{bindings:B}
    ).

compile_constraint(constraint(Id, Msg, Body), cons(Id, Msg, NV, Steps)) :-
    forall((member(I, Body), I \= cmp(_, _, _)), (arg(1, I, L), lit_key(L, K), ensure_pred(K))),
    numbered_body(Body, Pos, Filters),
    plan(Pos, Filters, Steps0), empty_assoc(M0), to_vars(Steps0, Steps, M0, M), assoc_to_list(M, NV).
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
        foldl(premise(D), Ps, Js, Budget, _), R = _{bindings:B, premises:Js}
    ;   R = _{bindings:B}
    ).

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
        ;   J = _{fact:LJ, by:Why}, B = B1
        )
    ).
premise(_, not(K-As), _{not:LJ}, B, B) :- !, lit_json(K, As, LJ).
premise(D, K-As, J, B0, B) :- proof(K-As, D, B0, B, J).

lit_json(P/_, Args, _{pred:P, args:Vs}) :- maplist([A, V]>>(var(A) -> V = "?_" ; V = A), Args, Vs).

%% Exportación: términos internos -> JSON del contrato

fact_json(fact(P, Vs), _{pred:P, args:Js}) :- maplist([V, J]>>term_json(c(V), J), Vs, Js).
rule_json(rule(Id, Head, Body), _{id:Id, head:HJ, body:BJ}) :- lit_out(Head, HJ), maplist(body_json, Body, BJ).
constraint_json(constraint(Id, M, Body), _{id:Id, message:M, body:BJ}) :- maplist(body_json, Body, BJ).
body_json(pos(L), J) :- lit_out(L, J).
body_json(neg(L), J) :- lit_out(L, J0), J = J0.put(not, true).
body_json(cmp(Op, A, B), _{cmp:Op, args:[AJ, BJ]}) :- term_json(A, AJ), term_json(B, BJ).
lit_out(lit(P, Ts), _{pred:P, args:Js}) :- maplist(term_json, Ts, Js).
term_json(v(N), J) :- string_concat("?", N, J).
term_json(c(V), J) :- (string(V), sub_string(V, 0, 1, _, "?") -> string_concat("?", V, J) ; J = V).

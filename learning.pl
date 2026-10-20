:- module(learning, [infer/2]).
:- use_module(library(assoc)).

% Contrato 1, reglas 1. La semántica no cambia; los índices evitan recorrer todas las
% aristas por nodo y por creencia.
infer(I, Conclusions) :-
    maplist(node_pair, I.nodes, Pairs), list_to_assoc(Pairs, Nodes),
    forall(member(E, I.edges), (get_assoc(E.from, Nodes, _), get_assoc(E.to, Nodes, _))),
    index_edges(I.edges, Motives, Supports),
    findall(C, (member(B, I.beliefs), evaluate(I, Nodes, Motives, Supports, B, State, Chains),
        Id = B.id, C = _{id:Id, status:State, rule:State, chains:Chains}), Conclusions),
    length(I.beliefs, Count), length(Conclusions, Count).
node_pair(N, Id-N) :- Id = N.id.

% motivada_por: From -> destinos ordenados y sin repetir; apoya: pares From-To.
index_edges(Edges, Motives, Supports) :-
    findall(F-T, (member(E, Edges), E.relation == "motivada_por", F = E.from, T = E.to), M0),
    keysort(M0, M1), group_pairs_by_key(M1, M2), maplist(sorted_targets, M2, M3),
    list_to_assoc(M3, Motives),
    findall((F-T)-t, (member(E, Edges), E.relation == "apoya", F = E.from, T = E.to), S0),
    sort(S0, S1), list_to_assoc(S1, Supports).
sorted_targets(F-Ts, F-Sorted) :- sort(Ts, Sorted).

% Mismo orden del contrato de aprendizaje: una propuesta no obtiene autoridad por inferencia.
evaluate(_, _, _, _, B, refutada, []) :- memberchk(B.state, ["revertida", "reemplazada"]), !.
evaluate(_, _, _, _, B, refutada, []) :- B.verdict == "refutada", !.
evaluate(_, _, _, _, B, sin_veredicto, []) :-
    \+ (B.state == "vigente", B.verdict == "validada", string(B.approved_by),
        sub_string(B.approved_by, 0, 8, _, "persona:")), !.
evaluate(_, Nodes, _, Supports, B, respaldo_retirado, []) :- \+ supported(Nodes, Supports, B), !.
evaluate(I, Nodes, Motives, _, B, State, Chains) :-
    chains(Motives, Nodes, B.id, Chains), validity(I, B, Chains, State).

supported(Nodes, Supports, B) :-
    get_assoc(B.id-B.evidence, Supports, _),
    get_assoc(B.evidence, Nodes, N), N.kind == "evidencia".

fallen(N) :- memberchk(N.kind-N.state,
    ["hallazgo"-"rechazado", "medicion"-"rechazada", "decision"-"revertida"]).

% BFS con visita única: un camino mínimo por respaldo caído, sin enumerar ciclos.
% La cola es Frente/Atrás para encolar en O(1) amortizado.
chains(Motives, Nodes, Root, Chains) :-
    empty_assoc(S0), put_assoc(Root, S0, t, Seen),
    bfs([[Root]], [], Seen, Motives, Nodes, Chains).
bfs([], [], _, _, _, []) :- !.
bfs([], Back, Seen, Motives, Nodes, Chains) :- !,
    reverse(Back, Front), bfs(Front, [], Seen, Motives, Nodes, Chains).
bfs([[Id|Path]|Front], Back, Seen, Motives, Nodes, Chains) :-
    (get_assoc(Id, Motives, Next) -> true ; Next = []),
    expand(Next, [Id|Path], Seen, Nodes, Seen2, More, Found),
    reverse(More, Rev), append(Rev, Back, Back2),
    bfs(Front, Back2, Seen2, Motives, Nodes, Rest), append(Found, Rest, Chains).
expand([], _, Seen, _, Seen, [], []).
expand([Id|Ids], Path, Seen, Nodes, FinalSeen, Queue, Found) :-
    (get_assoc(Id, Seen, _) -> expand(Ids, Path, Seen, Nodes, FinalSeen, Queue, Found)
    ; get_assoc(Id, Nodes, N), put_assoc(Id, Seen, t, Seen2),
      (fallen(N) -> reverse([Id|Path], Chain), Found = [Chain|RestFound], Queue = RestQueue
      ; N.kind == "decision" -> Queue = [[Id|Path]|RestQueue], Found = RestFound
      ; Queue = RestQueue, Found = RestFound),
      expand(Ids, Path, Seen2, Nodes, FinalSeen, RestQueue, RestFound)).

validity(_, _, [_|_], respaldo_caido) :- !.
validity(I, B, [], vencida) :- \+ (number(B.until), B.until > I.now), !.
validity(_, B, [], contexto_invalido) :- \+ valid_context(B.required), !.
validity(I, B, [], contexto_insuficiente) :-
    dict_pairs(B.required, _, Pairs), member(K-_, Pairs), \+ get_dict(K, I.context, _), !.
validity(I, B, [], fuera_de_contexto) :-
    dict_pairs(B.required, _, Pairs), member(K-V, Pairs), get_dict(K, I.context, Actual), V \== Actual, !.
validity(_, _, [], aplicable).

valid_context(D) :- is_dict(D), dict_pairs(D, _, Pairs), forall(member(K-V, Pairs),
    (memberchk(K, [agente,modelo,fase,tipo_trabajo,tecnologia,area,version_agente,version_modelo]), string(V))).

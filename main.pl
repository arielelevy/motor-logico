:- use_module(library(http/json)).
:- use_module(library(time)).
:- use_module(learning).
:- use_module(logic).

% Protocolo independiente: un JSON por stdin, un JSON por stdout. Nunca recibe goals.
% Contrato 1: dominio learning, sin persistencia (Lienzo). Contratos 2 y 3: dominio logic.
% Un fallo sale con código 2 y {"error", "code"} por stderr, nunca como respuesta vacía.
% La respuesta se serializa completa antes de escribirla: un error nunca deja stdout a medias.
main :-
    forall(member(S, [user_input, user_output, user_error]), set_stream(S, encoding(utf8))),
    catch(call_with_time_limit(35, (
              (run(Output) -> true ; throw(motor_error(invalid_snapshot, "La consulta no pudo resolverse"))),
              with_output_to(string(Text), json_write_dict(current_output, Output, [width(0)])))),
          E, fail_with(E)),
    write(Text), nl.

run(Output) :-
    json_read_dict(user_input, Input, [value_string_as(string)]),
    only_whitespace_left(user_input),
    (is_dict(Input), get_dict(contract, Input, C) -> true
    ; throw(motor_error(invalid_request, "La consulta debe ser un objeto con contract"))),
    dispatch(C, Input, Output).

only_whitespace_left(In) :-
    peek_char(In, C),
    (   C == end_of_file
    ->  true
    ;   char_type(C, space)
    ->  get_char(In, _), only_whitespace_left(In)
    ;   throw(motor_error(invalid_json, "Hay texto después del JSON; se espera una sola consulta"))
    ).

dispatch(1, Input, Output) :- !,
    (get_dict(domain, Input, "learning") -> true
    ; throw(motor_error(unsupported_domain, "El contrato 1 sólo admite domain \"learning\""))),
    call_with_time_limit(2, call_with_inference_limit(learning:infer(Input, Conclusions), 1000000, Limit)),
    (Limit == inference_limit_exceeded -> throw(motor_error(inference_limit, "Se excedió el límite de inferencias")) ; true),
    Output = _{contract:1, domain:learning, rules:1, authority:observation_only, conclusions:Conclusions}.
dispatch(2, Input, Output) :- !, logic_request(2, Input, Output).
dispatch(3, Input, Output) :- !, logic_request(3, Input, Output).
dispatch(_, _, _) :- throw(motor_error(unsupported_contract, "Contrato no soportado; versiones disponibles: 1, 2, 3")).

fail_with(E) :-
    error_info(E, Code, Message0),
    (string_length(Message0, L), L > 500 -> sub_string(Message0, 0, 500, _, M1), string_concat(M1, "…", Message)
    ; Message = Message0),
    json_write_dict(user_error, _{error:Message, code:Code}, [width(0)]), nl(user_error), halt(2).

error_info(motor_error(Code, Message), Code, Message) :- !.
error_info(time_limit_exceeded, time_limit, "Se excedió el límite de tiempo") :- !.
error_info(error(syntax_error(_), _), invalid_json, "La entrada no es JSON válido") :- !.
error_info(error(resource_error(_), _), resource_limit, "Se excedió un límite de recursos") :- !.
error_info(E, invalid_request, Message) :- message_to_string(E, Message).

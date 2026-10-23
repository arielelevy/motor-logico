% Contrato 4: JSONL persistente. Contratos 1-3 permanecen en main.pl.
% Los .pl de Lienzo contienen términos ground de datos; nunca goals del cliente.
:- ensure_loaded(main).
:- use_module(library(readutil)).
:- use_module(library(crypto)).
:- dynamic programa_cache/3.

servicio_main :-
    forall(member(S, [user_input,user_output,user_error]), set_stream(S,encoding(utf8))),
    flag(servicio_cargas,_,0), servicio_loop(none).

servicio_loop(Worker) :-
    read_line_to_string(user_input, Line),
    (Line == end_of_file -> servicio_terminar(Worker)
    ; servicio_esperar(Worker), thread_create(servicio_emitir(Line),Next,[]), servicio_loop(Next)).

servicio_esperar(none) :- !.
servicio_esperar(Id) :- thread_join(Id,_).
servicio_terminar(none) :- !.
servicio_terminar(Id) :-
    catch(thread_signal(Id,throw(motor_error(cancelled,"stdin cerrado: consulta cancelada"))),_,true),
    thread_join(Id,_).
servicio_emitir(Line) :-
    catch(servicio_line(Line,Out),E,servicio_error(E,null,Out)),
    json_write_dict(user_output,Out,[width(0)]),nl,flush_output.

servicio_line(Line, Out) :-
    string_length(Line,N),
    (N =< 4194304 -> true ; throw(motor_error(too_large,"consulta mayor a 4 MiB"))),
    atom_json_dict(Line, In, [value_string_as(string)]),
    (get_dict(request_id,In,Id),string(Id) -> true ; throw(motor_error(invalid_request,"falta request_id"))),
    catch(call_with_time_limit(30, servicio_request(In, Data)), E, servicio_error(E,Id,Data)),
    (get_dict(ok,Data,_) -> Out=Data ; Out=Data.put(_{request_id:Id,ok:true})).

servicio_error(E, Id, _{request_id:Id,ok:false,error:M,code:C}) :- error_info(E,C,M).

servicio_request(In, Out) :-
    (get_dict(contract,In,4), get_dict(op,In,"query"), get_dict(payload,In,Payload),is_dict(Payload),
     get_dict(archivos,In,Files),is_list(Files),length(Files,N),N=<100
     -> true ; throw(motor_error(invalid_request,"contrato persistente inválido"))),
    % No habilitar almacenes ni escrituras por el canal persistente de las creencias.
    (member(K,[store,assert,retract]),get_dict(K,Payload,_) ->
        throw(motor_error(invalid_request,"el servicio de creencias es sólo lectura")) ; true),
    maplist(servicio_archivo,Files,Lists),append(Lists,Rules),
    (get_dict(rules,Payload,Own) -> true ; Own=[]),append(Own,Rules,All),
    P=Payload.put(rules,All),
    (get_dict(contract,P,3) -> true ; throw(motor_error(unsupported_contract,"payload requiere contrato 3"))),
    logic_request(3,P,Result), current_prolog_flag(pid,Pid),flag(servicio_cargas,Loads,Loads),
    Out=_{resultado:Result,pid:Pid,cargas:Loads}.

servicio_archivo(F, Rules) :-
    (is_dict(F),get_dict(path,F,Path),string(Path),get_dict(hash,F,Hash),string(Hash)
      -> true ; throw(motor_error(invalid_request,"archivo requiere path y hash"))),
    (programa_cache(Path,Hash,Rules) -> true
    ; crypto_file_hash(Path,Actual,[algorithm(sha256),encoding(octet)]),atom_string(Actual,ActualString),
      (ActualString==Hash -> true ; throw(motor_error(stale_file,"hash del archivo no coincide"))),
      setup_call_cleanup(open(Path,read,S,[encoding(utf8)]),servicio_terms(S,Terms),close(S)),
      servicio_reglas(Terms,Rules),
      % Validación semántica completa sin ejecutar ninguna regla con hechos del consumidor.
      logic_request(3,_{contract:3,domain:"logic",facts:[],rules:Rules,queries:[]},_),
      retractall(programa_cache(Path,_,_)),assertz(programa_cache(Path,Hash,Rules)),
      flag(servicio_cargas,C,C+1)).

servicio_terms(S, Terms) :-
    read_term(S,T,[syntax_errors(error),cycles(false)]),
    (T==end_of_file -> Terms=[]
    ; (ground(T),servicio_forma(T) -> true ; throw(motor_error(invalid_program,"término no permitido en proyección"))),
      Terms=[T|Rest],servicio_terms(S,Rest)).

servicio_forma(proyecto(P)) :- string(P).
servicio_forma(creencia(B,R,S)) :- maplist(string,[B,R,S]).
servicio_forma(regla_logica(B,J)) :- maplist(string,[B,J]).
servicio_forma(datos_creencia(B,J)) :- maplist(string,[B,J]).
servicio_forma(sin_formalizar(B)) :- string(B).

servicio_reglas(Terms, Rules) :-
    findall(R,(member(regla_logica(B,J),Terms),
      atom_json_dict(J,AST,[value_string_as(string)]),
      dict_pairs(AST,_,Pairs),pairs_keys(Pairs,Keys),sort(Keys,[body,head]),
      get_dict(head,AST,H),get_dict(body,AST,Body),
      string_concat("creencia_",B,Id),
      R=_{id:Id,head:H,body:[_{pred:"creencia_habilitada",args:[B]}|Body]}),Rules),
    % Un AST que no se pudo convertir no se ignora como si no tuviese reglas.
    findall(B,member(regla_logica(B,_),Terms),Bs),length(Bs,N),length(Rules,N).

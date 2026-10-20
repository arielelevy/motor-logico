:- module(store, [store_name/2, store_load/2, store_save/2, with_store_lock/2]).
:- use_module(library(filesex)).
:- use_module(library(process)).

% Almacenes del contrato 2: un archivo de términos Prolog por nombre, sólo datos.
% Se leen con read_term (nunca consult) y se reemplazan con rename atómico.
% Las escrituras se serializan entre procesos con un directorio-candado (mkdir es atómico).

:- dynamic home/1.
:- prolog_load_context(directory, D), assertz(home(D)).

err(Code, Format, Args) :- format(string(M), Format, Args), throw(motor_error(Code, M)).

data_dir(Dir) :-
    (   getenv('MOTOR_LOGICO_DATA', D), D \== ''
    ->  Dir = D
    ;   home(H), directory_file_path(H, data, Dir)
    ).

% Nombre seguro para usar como archivo: [a-z0-9][a-z0-9._-]{0,63}, sin "..".
store_name(Value, Name) :-
    (   string(Value), string_length(Value, L), between(1, 64, L),
        string_codes(Value, [C|Cs]), name_code(C, false), forall(member(X, Cs), name_code(X, true)),
        \+ sub_string(Value, _, _, _, ".."),
        \+ (split_string(Value, ".", "", [Base|_]),
             memberchk(Base, ["con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "lpt1", "lpt2", "lpt3"]))
    ->  Name = Value
    ;   err(invalid_store, "store debe ser [a-z0-9][a-z0-9._-]{0,63}", [])
    ).
name_code(C, _) :- between(0'a, 0'z, C), !.
name_code(C, _) :- between(0'0, 0'9, C), !.
name_code(C, true) :- memberchk(C, `._-`).

store_path(Name, Path) :- data_dir(Dir), atomic_list_concat([Dir, /, Name, '.pl'], Path).

% store(Revision, Hechos, Reglas, Restricciones); un almacén inexistente es revisión 0 vacía.
store_load(Name, Store) :-
    store_path(Name, Path),
    (   exists_file(Path)
    ->  catch(setup_call_cleanup(open(Path, read, S, [encoding(utf8)]), read_terms(S, Terms), close(S)),
              E, (message_to_string(E, M), err(corrupt_store, "No se pudo leer el almacén ~s: ~s", [Name, M]))),
        terms_store(Name, Terms, Store)
    ;   Store = store(0, [], [], [])
    ).
read_terms(S, Terms) :-
    read_term(S, T, [syntax_errors(error)]),
    (T == end_of_file -> Terms = [] ; Terms = [T|Rest], read_terms(S, Rest)).

terms_store(Name, [store_meta(1, Rev)|Terms], store(Rev, Facts, Rules, Constraints)) :-
    integer(Rev), Rev >= 0, ground(Terms), !,
    partition_terms(Terms, Facts0, Rules, Constraints), sort(Facts0, Facts),
    (   length(Terms, N), length(Facts0, NF), length(Rules, NR), length(Constraints, NC), N =:= NF + NR + NC
    ->  true
    ;   err(corrupt_store, "El almacén ~s tiene términos desconocidos", [Name])
    ).
terms_store(Name, _, _) :- err(corrupt_store, "El almacén ~s no tiene store_meta(1, Revisión) válido", [Name]).
partition_terms(Terms, Facts, Rules, Constraints) :-
    include([T]>>(T = fact(_, _)), Terms, Facts),
    include([T]>>(T = rule(_, _, _)), Terms, Rules),
    include([T]>>(T = constraint(_, _, _)), Terms, Constraints).

store_save(Name, store(Rev, Facts, Rules, Constraints)) :-
    store_path(Name, Path), file_directory_name(Path, Dir), make_directory_path(Dir),
    current_prolog_flag(pid, Pid), format(atom(Tmp), "~w.~w.tmp", [Path, Pid]),
    catch(( setup_call_cleanup(open(Tmp, write, S, [encoding(utf8)]),
                ( format(S, "% motor-logico · almacén ~s · sólo datos, no consultar como código~n", [Name]),
                  write_fact(S, store_meta(1, Rev)),
                  forall(member(T, Facts), write_fact(S, T)),
                  forall(member(T, Rules), write_fact(S, T)),
                  forall(member(T, Constraints), write_fact(S, T)) ),
                close(S)),
            % Releer antes de reemplazar: nunca se publica un almacén que no se pueda volver a leer.
            setup_call_cleanup(open(Tmp, read, R, [encoding(utf8)]), read_terms(R, Back), close(R)),
            append([store_meta(1, Rev)|Facts], Rules, T0), append(T0, Constraints, Expected),
            (Back == Expected -> true ; err(corrupt_store, "El almacén ~s no se releyó igual; no se guardó", [Name])),
            durable(Tmp), rename_file(Tmp, Path), durable(Dir) ),
          E, (catch(delete_file(Tmp), _, true), throw(E))).
% fsync del archivo antes del rename y de la carpeta después, así un corte de energía no deja
% un almacén vacío. SWI no expone fsync: `sync <ruta>` de coreutils lo hace para esa ruta.
durable(Path) :-
    (   absolute_file_name(path(sync), Sync, [access(execute), file_errors(fail)])
    ->  process_create(Sync, [Path], [stdin(null), stdout(null), stderr(null), process(P)]),
        process_wait(P, Status),
        (Status == exit(0) -> true ; err(store_io, "No se pudo sincronizar ~w con el disco", [Path]))
    ;   true
    ).
write_fact(S, T) :- write_term(S, T, [quoted(true), ignore_ops(true), fullstop(true), nl(true)]).

% Candado entre procesos: un directorio (mkdir es atómico) con owner(Pid, Token) adentro.
% Se roba de forma atómica (rename) si su dueño ya no existe en este sistema o si tiene
% más de 120 s; se libera sólo si el token sigue siendo el propio. Espera hasta ~3 s.
:- meta_predicate with_store_lock(+, 0).
with_store_lock(Name, Goal) :-
    store_path(Name, Path), file_directory_name(Path, Dir), make_directory_path(Dir),
    atom_concat(Path, '.lock', Lock),
    current_prolog_flag(pid, Pid), random_between(1, 1000000000, Rnd), Token = Pid-Rnd,
    acquire(Lock, Token, 30),
    setup_call_cleanup(true, once(Goal), release(Lock, Token)).

acquire(Lock, Token, Tries) :-
    catch(make_directory(Lock), E, true),
    (   var(E)
    ->  Token = Pid-_, owner_file(Lock, F),
        setup_call_cleanup(open(F, write, S), write_fact(S, owner(Pid, Token)), close(S))
    ;   \+ exists_directory(Lock)
    ->  throw(E)
    ;   stale(Lock)
    ->  steal(Lock, Token), acquire(Lock, Token, Tries)
    ;   Tries > 0
    ->  sleep(0.1), T1 is Tries - 1, acquire(Lock, Token, T1)
    ;   err(store_busy, "El almacén está bloqueado por otra escritura; reintentá", [])
    ).
owner_file(Lock, F) :- directory_file_path(Lock, owner, F).
owner(Lock, Pid, Token) :-
    owner_file(Lock, F),
    catch(setup_call_cleanup(open(F, read, S), read_term(S, owner(Pid, Token), []), close(S)), _, fail).
stale(Lock) :-
    catch(time_file(Lock, T), _, fail), get_time(Now),
    (   Now - T > 120
    ->  true
    ;   Now - T > 1, exists_directory('/proc/self'), owner(Lock, Pid, _), integer(Pid),
        format(atom(Proc), "/proc/~w", [Pid]), \+ exists_directory(Proc)
    ).
steal(Lock, Token) :-
    format(atom(Old), "~w.stale.~w", [Lock, Token]),
    (   catch(rename_file(Lock, Old), _, fail)
    ->  remove_lock_dir(Old)
    ;   true
    ).
release(Lock, Token) :-
    (owner(Lock, _, Token) -> remove_lock_dir(Lock) ; true).
remove_lock_dir(D) :-
    owner_file(D, F), catch(delete_file(F), _, true), catch(delete_directory(D), _, true).

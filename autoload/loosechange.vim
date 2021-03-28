if exists('g:autoloaded_loosechange')
  finish
endif
let g:autoloaded_loosechange = 1

" -------------
" Main Function
" -------------

function! loosechange#Run(type, command, is_outer)
    let insert_after = 0

    " Convert 'c' to 'd' and set insert mode after
    let cmd = a:command
    if cmd ==# 'c'
        let insert_after = 1
        let cmd = 'd'
    endif

    if has_key(g:loosechange_builtin_keys, a:type)
        let cmd = a:is_outer ? cmd.'a' : cmd.'i'
        let functions = {
            \ 'in_place': { _ -> s:cursor_in_symbol(a:type)},
            \ 'navigate': { _ -> execute('normal! f'.a:type)},
            \ 'command': { _ -> execute('normal! '.cmd.a:type)}
        \ }
    elseif has_key(g:loosechange_custom_keys, a:type)
        let functions = {
            \ 'in_place': { ast -> s:cursor_in_tag(ast, a:type)},
            \ 'navigate': { ast -> s:navigate_tag(ast, a:type)},
            \ 'command': { ast -> s:operate_tag(ast, a:type, cmd, a:is_outer)}
        \ }
    else
        return
    endif

    call s:navigate_and_run(functions)

    if insert_after
        startinsert
    endif
endfunction

function! s:navigate_and_run(functions)
    let count = v:count1

    " For advanced functions
    let tokens = loosechange#Tokenize()
    let ast = loosechange#BuildAST(tokens, {'type': 'root'})
    call s:apply_tags(ast)

    " If already in place, no need to navigate
    if a:functions['in_place'](ast)
        let count -= 1
    endif

    " Set initial position to restore to later
    let initial_pos = getpos('.')
    let current_pos = initial_pos

    " navigate to next instance for each count
    while count > 0
        " navigate
        call a:functions['navigate'](ast)

        " Return and revert position if nothing found
        if getpos('.') == current_pos
            call setpos('.', initial_pos)
            return
        endif

        let current_pos = getpos('.')
        let count -= 1
    endwhile

    " Execute command
    call a:functions['command'](ast)
endfunction

function! s:cursor_in_symbol(symbol)
    let backup = @l
    let @l = ""
    exe 'normal! "lyi'.a:symbol

    let value = @l

    let @l = backup

    return len(value) > 0
endfunction

" -----------------
" Parsing Functions
" -----------------

" This builds a very simple AST that is only aware of parentheses and braces
" The rest of the types will be denoted with tags.
function! loosechange#BuildAST(tokens, node)
    let node = s:create_node(a:node)
    let tokens = a:tokens

    while !empty(tokens)
        let token = tokens[0]

        let item = {}

        " Parentheses
        if token['type'] ==# 'lparen'
            call remove(tokens, 0)
            let item = loosechange#BuildAST(tokens, {'type': 'parens', 'start': token['start']})
        elseif token['type'] ==# 'rparen' && node['type'] ==# 'parens'
            call remove(tokens, 0)
            let node['end'] = token['end']
            break

        " Braces
        elseif token['type'] ==# 'lbrace'
            call remove(tokens, 0)

            let item = loosechange#BuildAST(tokens, {'type': 'braces', 'start': token['start']})
        elseif token['type'] ==# 'rbrace' && node['type'] ==# 'braces'
            call remove(tokens, 0)

            let node['end'] = token['end']
            break

        else
            call remove(tokens, 0)
            let item = s:create_node(token)
        endif

        if !empty(item)
            call add(node['children'], item)
        endif
    endwhile

    if !has_key(node, 'start')
        let node['start'] = node['children'][0]['start']
    endif
    if !has_key(node, 'end')
        let node['end'] = node['children'][-1]['end']
    endif

    return node
endfunction

" Hacky method to apply tags to nodes in AST
function! s:apply_tags(ast)
    let children = a:ast['children']

    " Key-value
    let indexes = s:find_pattern(children, ['(id|string)', 'colon'])
    for index in indexes
        " Ignore if followed by extra colon
        let value_node = get(children, index + 2, {})
        if get(value_node, 'type') ==# 'colon'
            continue
        endif

        let children[index]['tags']['key'] = {
            \ 'start': children[index]['start'],
            \ 'end': children[index + 1]['end'] - 1,
            \ 'outer_end': children[index + 1]['end']
        \ }

        " Set value
        if empty(value_node)
            continue
        endif
        let value_start = value_node['start']

        let value_index = index + 2
        let value_node = get(children, value_index + 1, {})
        while !empty(value_node) && index(['colon', 'comma'], value_node['type']) == -1
            let value_index += 1
            let value_node = get(children, value_index + 1, {})
        endwhile

        let children[index + 2]['tags']['value'] = {
            \ 'start': value_start,
            \ 'end': children[value_index]['end']
        \ }
    endfor

    " Arguments
    if !empty(s:find_pattern(children, ['comma']))
        let i = 0
        let args = []
        while i < len(children)
            if children[i]['type'] ==# 'comma' && len(args)
                let args[0]['tags']['arg'] = {
                    \ 'start': args[0]['start'],
                    \ 'end': args[-1]['end']
                \ }
                let args = []
            else
                call add(args, children[i])
            endif
            let i += 1
        endwhile

        " Check for last arg
        if len(args)
            let args[0]['tags']['arg'] = {
                \ 'start': args[0]['start'],
                \ 'end': args[-1]['end']
            \ }
        endif
    endif

    for node in children
        call s:apply_tags(node)
    endfor
endfunction

function! s:find_pattern(nodes, pattern)
    let types = map(copy(a:nodes), {_, node -> node['type']})

    let matches = []
    let i = 0
    while i + len(a:pattern) <= len(types)
        if s:matches_pattern(types[i:i + len(a:pattern) - 1], a:pattern)
            call add(matches, i)
        endif

        let i += 1
    endwhile

    return matches
endfunction

function! s:matches_pattern(types_list, pattern)
    if len(a:types_list) != len(a:pattern)
        return 0
    endif

    let i = 0
    while i < len(a:types_list)
        if a:types_list[i] !~# '\v^'.a:pattern[i].'$'
            return 0
        endif

        let i += 1
    endwhile

    return 1
endfunction

function! loosechange#Tokenize()
    let i = 1
    let tokens = []
    let current_token = {}

    let quote_char = ''
    let ignore_next = 0
    while 1
        let char = s:get_char_at(i)

        if char ==# ''
            break
        endif

        if ignore_next
            let ignore_next = 0
        elseif char ==# '\'
            let ignore_next = 1

        " In existing string
        elseif quote_char != ''
            " If closing string
            if char ==# quote_char
                " Reset quote
                let quote_char = ''

                " Finish token
                let current_token['end'] = i
                call add(tokens, current_token)

                let current_token = {}
            endif

        " New string
        " TODO: add support for `
        elseif char =~# '[''"]' && get(current_token, 'type', '') !=# 'id'
            let current_token = s:create_token(tokens, current_token, i, 'string')
            let quote_char = char

        elseif char ==# ':'
            let current_token = s:create_token(tokens, current_token, i, 'colon')

        elseif char ==# '('
            let current_token = s:create_token(tokens, current_token, i, 'lparen')

        elseif char ==# ')'
            let current_token = s:create_token(tokens, current_token, i, 'rparen')

        elseif char ==# '{'
            let current_token = s:create_token(tokens, current_token, i, 'lbrace')

        elseif char ==# '}'
            let current_token = s:create_token(tokens, current_token, i, 'rbrace')

        elseif char ==# ','
            let current_token = s:create_token(tokens, current_token, i, 'comma')

        " Alphanumeric or quote
        elseif char =~# '\v(\w|[''"])'
            let current_token = s:create_token(tokens, current_token, i, 'id')
        " Whitespace
        elseif char =~# '\v\s'
            let current_token = s:create_token(tokens, current_token, i, 'space')

        " Other
        else
            let current_token = s:create_token(tokens, current_token, i, 'other')
        endif

        let i += 1
    endwhile

    " Create fake token to push existing token
    call s:create_token(tokens, current_token, i, 'end')

    " Remove whitespace
    return filter(tokens, {idx, token -> token['type'] !=# 'space'})
endfunction

let s:CONTINUABLE_TYPES = ['id', 'string']
function! s:create_token(tokens, current_token, index, new_type)
    " Return current token if continuation of existing token
    if get(a:current_token, 'type', '') ==# a:new_type && index(s:CONTINUABLE_TYPES, a:new_type) != -1
        return a:current_token
    endif

    if !empty(a:current_token)
        let a:current_token['end'] = a:index - 1
        call add(a:tokens, a:current_token)
    endif

    return {'start': a:index, 'type': a:new_type}
endfunction

function! s:create_node(d)
    let node = {'children': [], 'tags': {}}
    for [k, v] in items(a:d)
        let node[k] = v
    endfor
    return node
endfunction

" Dumb way to get the exact character under the cursor
" https://stackoverflow.com/a/23323958
function! s:get_char_at(col)
    return matchstr(getline('.'), '\%'.a:col.'c.')
endfunction

" -------------
" Tag Functions
" -------------
"
"  Because we don't have a true AST, we are using tags to the note the types
"  of certain tokens. A token may have multiple tags.

function! s:cursor_in_tag(ast, tag)
    let tags = s:find_tags(a:ast, a:tag)
    let current_col = col('.')

    for tag in tags
        if current_col >= tag['start'] && current_col <= tag['end']
            return 1
        endif
    endfor

    return 0
endfunction

function! s:navigate_tag(ast, tag)
    let tags = s:find_tags(a:ast, a:tag)
    let current_col = col('.')

    for tag in tags
        if current_col < tag['start']
            let difference = tag['start'] - current_col
            exe 'normal! '.difference.'l'
            return
        endif
    endfor
endfunction

function! s:operate_tag(ast, tag, command, is_outer)
    let tags = s:find_tags(a:ast, a:tag)
    let current_col = col('.')

    for tag in tags
        if current_col >= tag['start'] && current_col <= tag['end']
            let tag_end = tag['end']
            if a:is_outer
                let tag_end = has_key(tag, 'outer_end') ? tag['outer_end'] : tag_end
                " Let tag_end extend past all whitespace
                while s:get_char_at(tag_end + 1) =~# '\v\s'
                    let tag_end += 1
                endwhile
            endif

            " Visual mode includes last character, unlike other commands
            if a:command ==# 'v'
                let tag_end -= 1
            endif

            " Set cursor column to start and run command until end
            let difference = tag_end + 1 - tag['start']
            exe 'normal! '.tag['start'].'|'.a:command.difference.'l'
            return
        endif
    endfor
endfunction

function! s:find_tags(ast, tag)
    let found = []

    for child in a:ast['children']
        if has_key(child['tags'], a:tag)
            let found += [child['tags'][a:tag]]
        else
            let found += s:find_tags(child, a:tag)
        endif
    endfor

    return found
endfunction

" ---------------
" Debug Functions
" ---------------

function! loosechange#DebugAST()
    let tokens = loosechange#Tokenize()
    let ast = loosechange#BuildAST(tokens, {'type': 'root'})
    call s:apply_tags(ast)
    call s:debug_print_ast(ast, 0)
endfunction

function! s:debug_print_ast(node, level)
    echom repeat(' ', a:level).a:node['type'].' '.a:node['start'].':'.a:node['end'].' '.string(a:node['tags'])
    for child in a:node['children']
        call s:debug_print_ast(child, a:level + 1)
    endfor
endfunction

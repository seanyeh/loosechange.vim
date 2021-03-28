if exists('g:loaded_loosechange')
  finish
endif
let g:loaded_loosechange = 1

if !exists('g:loosechange_no_defaults')
    let g:loosechange_no_defaults = 0
endif

" Allowed commands for loosechange
let s:commands = ['c', 'd', 'v', 'y']

" Mappings for function key -> shortcut key
let g:loosechange_builtin_keys = {'(': '(', '{': '{', '[': '[', '<': '<'}
let g:loosechange_custom_keys = {'key': 'k', 'value': 'v', 'arg': 'a'}

if !g:loosechange_no_defaults
    for cmd in s:commands
        for [fk, sk] in items(g:loosechange_builtin_keys) + items(g:loosechange_custom_keys)
            exe 'nnoremap '.cmd.'i'.sk.' :<C-U>call loosechange#Run("'.fk.'", "'.cmd.'", 0)<CR>'
            exe 'nnoremap '.cmd.'a'.sk.' :<C-U>call loosechange#Run("'.fk.'", "'.cmd.'", 1)<CR>'
        endfor
    endfor
endif

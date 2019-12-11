" buffers - Track listed buffers
" +{buffer_id} :Dictionary: buffer_id is key, contain following items:
" Basic Info:
"   -head    :List: buffer's directory abspath, split by `s:path_separator`
"   -not_new :Number: it's not new if len(@tail) > 0; not [No Name] file ?
"   -tail    :String: buffer's filename
" State Info:
"   -index  :Number: (-1) index for taking @head's basename, combine with
"     @name to distinguish identical filename, decrease if still identical
"   -name   :String: filename to display on tabline
"   -length :Number: filename length
let s:buffers = {}

" buffer_ids - Because buffers{} doesn't store buffers in order,
" that's why we need this for UI process
"
" => (List)-Numbers:
"   ${buffet_id}: buffer id; list indexes is the order
"
" Future Feature: (XXX) I think we can reorder this to employment swap buffers.
let s:buffer_ids = []

" when the focus switches to another *unlisted* buffer, it does not appear in
" the tabline, thus the tabline will list starting from the first buffer. For
" this, we keep track of the last current buffer to keep the tabline "position"
" in the same place.
let s:last_current_buffer_id = -1

" when you delete a buffer with the highest ID, we will never loop up there and
" it will always stay in the buffers list, so we need to remember the largest
" buffer ID.
let s:largest_buffer_id = 1

" either a slash or backslash
let s:path_separator = fnamemodify(getcwd(),':p')[-1:]

" ======================

function! buffet#update()

    " Phase I: Init or Update buffers basic info
    " ==========================================
    let largest_buffer_id = max([bufnr('$'), s:largest_buffer_id])

    for buffer_id in range(1, largest_buffer_id)
        let is_tracked = has_key(s:buffers, buffer_id) ? 1 : 0

        " Skip if a buffer with this id does not exist in `buflisted`:
        " bdelete, floating_window, term, not exists, ...
        if !buflisted(buffer_id)
            " Clear this buffer if it is being tracked by `buffers{}`
            if is_tracked
                call remove(s:buffers, buffer_id)
                call remove(s:buffer_ids, index(s:buffer_ids, buffer_id))

                " Reassign because the buffer of s:last_current_buffer_id is
                " clear ? For bdelete case only ?
                if buffer_id == s:last_current_buffer_id
                    let s:last_current_buffer_id = -1
                endif

                let s:largest_buffer_id = max(s:buffer_ids)
            endif
            continue
        endif

        " If this buffer is already tracked and listed, we're good.
        " In case if it is the only buffer, still update, because an empty new
        " buffer id is being replaced by a buffer for an existing file.
        if is_tracked && len(s:buffers) > 1
            continue
        endif

        " Hide & skip terminal and quickfix buffers
        if s:IsTermOrQuickfix(buffer_id)
            call setbufvar(buffer_id, "&buflisted", 0)
            continue
        endif

        " Update the buffers map
        let s:buffers[buffer_id] = s:ComposeBufferInfo(buffer_id)

        if !is_tracked
            " Update the buffer IDs list
            call add(s:buffer_ids, buffer_id)
            " FIXME: Wtf is this ? Why though ?
            let s:largest_buffer_id = max([s:largest_buffer_id, buffer_id])
        endif
    endfor

    " Phase II: Handling identical filenames
    " ======================================
    " buffer_name_count - Memoize identical filenames
    " +{buffer.name} :Number: count
    let buffer_name_count = {}

    " Set initial buffer name, and record occurrences
    for buffer in values(s:buffers)
        let buffer            = extend(buffer, s:InitOccState(buffer))
        let buffer_name_count = extend(buffer_name_count,
            \   s:RecordOcc(buffer_name_count, buffer))
    endfor

    " Disambiguate buffer names with multiple occurrences
    while len(filter(buffer_name_count, 'v:val > 1'))
        let ambiguous = buffer_name_count
        let buffer_name_count = {}

        " Update buffer name; and record occurrences after changed
        for buffer in values(s:buffers)
            if has_key(ambiguous, buffer.name)
                let buffer = extend(buffer, s:UpdateOccState(buffer))
            endif

            let buffer_name_count = extend(buffer_name_count,
                \   s:RecordOcc(buffer_name_count, buffer))
        endfor
    endwhile

    " Phase III: Update current buffer, s:last_current_buffer_id
    " ==========================================================
    let current_buffer_id = bufnr('%')

    if has_key(s:buffers, current_buffer_id)
        let s:last_current_buffer_id = current_buffer_id
    " FIXME: Delete this !!!
    elseif s:last_current_buffer_id == -1 && len(s:buffer_ids) > 0
        let s:last_current_buffer_id = s:buffer_ids[0]
    endif

    " Phase IV: Misc
    " ===============
    " FIXME: Break this !!!
    " Hide tabline if only one buffer and tab open
    if !g:buffet_always_show_tabline && len(s:buffer_ids) == 1 && tabpagenr("$") == 1
        set showtabline=0
    endif
endfunction


" IsTermOrQuickfix - Return TRUE (1) if it's a Terminal or Quickfix buffer
" @bufid | Number: buffer_id is used to check
"
" => :Boolean:
" ---
function! s:IsTermOrQuickfix(bufid) abort
    let buffer_type = getbufvar(a:bufid, "&buftype", "")
    if index(["terminal", "quickfix"], buffer_type) >= 0
        return v:true
    endif
    return v:false
endfunction


" ComposeBufferInfo - Compose @head, @not_new, @tail of buffers{} based on buffer_id
" @bufid | Number: buffer_id
"
" => buffer{} | Dictionary: Return a dictionary contains 3 items:
"   -head | String:
"   -now_new | Number:
"   -tail | String:
" ---
function! s:ComposeBufferInfo(bufid) abort
    let buffer_name = bufname(a:bufid)
    let buffer_head = fnamemodify(buffer_name, ':p:h')
    let buffer_tail = fnamemodify(buffer_name, ':t')

    " Initialize the buffer object
    let buffer = {}
    let buffer.head = split(buffer_head, s:path_separator)
    let buffer.not_new = len(buffer_tail)
    let buffer.tail = buffer.not_new ? buffer_tail : g:buffet_new_buffer_name

    return buffer
endfunction


" InitAndRecordOcc - Init buffer's state and record occurrences
" @buf | Dictionary: the buffer
"
" => buffer{} | Dictionary:
"    -index
"    -name
"    -length
function! s:InitOccState(buf) abort
    let buffer = {}
    let buffer.index = -1
    let buffer.name = a:buf.tail
    let buffer.length = len(buffer.name)

    return buffer
endfunction


" RecordOcc - Record occurrences
" @buffer_name_count :Dictionary:
" @buf :Dictionary: the buffer
"
" => | Dictionary: return the following dic OR an empty dic {} if a:now_new == 0
"   ${buf.name} :Number: current_count
" ---
function! s:RecordOcc(buffer_name_count, buf) abort
    if a:buf.not_new
        let l:current_count = get(a:buffer_name_count, a:buf.name, 0)
        return { a:buf.name: l:current_count+1 }
    endif
    return {}
endfunction


" UpdateOccState - Update buffers's state
" @buf :Dictionary: buffer item from buffers{}
"
" => buffer{} :Dictionary:
"   $index  :Number: decrease the index
"   $name   :String:
"   $length :Number:
function! s:UpdateOccState(buf) abort
    let buffer_path = a:buf.head[a:buf.index:]
    call add(buffer_path, a:buf.tail)

    let buffer = {}
    let buffer.index = a:buf.index - 1
    let buffer.name = join(buffer_path, s:path_separator)
    let buffer.length = len(buffer.name)

    return buffer
endfunction


" UI ==========================================================================
function! buffet#render()
    call buffet#update()
    return s:Render()
endfunction


function! s:Render()
    let sep_len = s:Len(g:buffet_separator)

    let tabs_count = tabpagenr("$")
    let tabs_len = (1 + s:Len(g:buffet_tab_icon) + 1 + sep_len) * tabs_count

    let left_trunc_len = 1 + s:Len(g:buffet_left_trunc_icon) + 1 + 2 + 1 + sep_len
    let right_trunc_len =  1 + 2 + 1 + s:Len(g:buffet_right_trunc_icon) + 1 + sep_len
    let trunc_len = left_trunc_len + right_trunc_len

    let capacity = &columns - tabs_len - trunc_len - 5
    let buffer_padding = 1 + (g:buffet_use_devicons ? 1+1 : 0) + 1 + sep_len

    let elements = s:GetAllElements(capacity, buffer_padding)

    let render = ""
    for i in range(0, len(elements) - 2)
        let left = elements[i]
        let elem = left
        let right = elements[i + 1]

        if elem.type == "Tab"
            let render = render . "%" . elem.value . "T"
        elseif s:IsBufferElement(elem) && has("nvim")
            let render = render . "%" . elem.buffer_id . "@SwitchToBuffer@"
        endif

        let highlight = s:GetTypeHighlight(elem.type)
        let render = render . highlight

        if g:buffet_show_index && s:IsBufferElement(elem)
            let render = render . " " . elem.index
        endif

        let icon = ""
        if g:buffet_use_devicons && s:IsBufferElement(elem)
            let icon = " " . WebDevIconsGetFileTypeSymbol(elem.value)
        elseif elem.type == "Tab"
            let icon = " " . g:buffet_tab_icon
        endif

        let render = render . icon

        if elem.type != "Tab"
            let render = render . " " . elem.value
        endif

        if s:IsBufferElement(elem)
            if elem.is_modified && g:buffet_modified_icon != ""
                let render = render . g:buffet_modified_icon
            endif
        endif

        let render = render . " "

        let separator =  g:buffet_has_separator[left.type][right.type]
        let separator_hi = s:GetTypeHighlight(left.type . right.type)
        let render = render . separator_hi . separator

        if elem.type == "Tab" && has("nvim")
            let render = render . "%T"
        elseif s:IsBufferElement(elem) && has("nvim")
            let render = render . "%T"
        endif
    endfor

    if !has("nvim")
        let render = render . "%T"
    endif

    let render = render . s:GetTypeHighlight("Buffer")

    return render
endfunction


" `GetTablineElements`
" GetAllElements:
"
" => tab_elems[]:
"   $1|tabs{} = value | type
"   $2|buffers[{}] = ...
"   $3|end{} = 
" ---
function! s:GetAllElements(capacity, buffer_padding)
    let last_tab_id     = tabpagenr('$')
    let current_tab_id  = tabpagenr()
    let buffer_elems    = s:GetBufferElements(a:capacity, a:buffer_padding)
    let end_elem        = {"type": "End", "value": ""}

    let tab_elems = []

    for tab_id in range(1, last_tab_id)
        " Tab(s)
        let elem = {}
        let elem.value = tab_id
        let elem.type = "Tab"
        call add(tab_elems, elem)

        " Buffer(s)
        if tab_id == current_tab_id
            let tab_elems = tab_elems + buffer_elems
        endif
    endfor

    " End
    call add(tab_elems, end_elem)

    return tab_elems
endfunction



" GetBufferElements:
" 
" => buffer_elems[{}] (List)-Dicts:
"   $1|left_trunc_elem{}:
"   $2|
function! s:GetBufferElements(capacity, buffer_padding)
    let [left_i, right_i] = s:GetVisibleRange(a:capacity, a:buffer_padding)
    " TODO: evaluate if calling this ^ twice will get better visuals

    if left_i < 0 || right_i < 0
        return []
    endif

    let buffer_elems = []

    let trunced_left = left_i
    if trunced_left
        let left_trunc_elem = {}
        let left_trunc_elem.type = "LeftTrunc"
        let left_trunc_elem.value = g:buffet_left_trunc_icon . " " . trunced_left
        call add(buffer_elems, left_trunc_elem)
    endif

    " Visible buffers
    for i in range(left_i, right_i)
        let buffer_id = s:buffer_ids[i]
        let buffer = s:buffers[buffer_id]

        if buffer_id == winbufnr(0)
            let type_prefix = "Current"
        elseif bufwinnr(buffer_id) > 0
            let type_prefix = "Active"
        else
            let type_prefix = ""
        endif

        let elem = {}
        let elem.index = i + 1
        let elem.value = buffer.name
        let elem.buffer_id = buffer_id
        let elem.is_modified = getbufvar(buffer_id, '&mod')

        if elem.is_modified
            let type_prefix = "Mod" . type_prefix
        endif

        let elem.type = type_prefix . "Buffer"

        call add(buffer_elems, elem)
    endfor

    let trunced_right = (len(s:buffers) - right_i - 1)
    if trunced_right > 0
        let right_trunc_elem = {}
        let right_trunc_elem.type = "RightTrunc"
        let right_trunc_elem.value = trunced_right . " " . g:buffet_right_trunc_icon
        call add(buffer_elems, right_trunc_elem)
    endif

    return buffer_elems
endfunction



" GetVisibleRange: 
" @length_limit (Number)
" @buffer_padding (Number)
"
" => (List): (Numbers):
"   $1|left_idx: Number of names trunced_left
"   $2|right_idx: 
" ---
function! s:GetVisibleRange(length_limit, buffer_padding)
    let current_buffer_id = s:last_current_buffer_id

    if current_buffer_id == -1
        return [-1, -1]
    endif

    let current_buffer_id_idx = index(s:buffer_ids, current_buffer_id)
    let current_buffer        = s:buffers[current_buffer_id]

    let capacity = a:length_limit - current_buffer.length - a:buffer_padding

    let [left_idx, capacity] = s:GetTruncedItems(current_buffer_id_idx,
        \   capacity, a:buffer_padding, 'left')
    let [right_idx, capacity] = s:GetTruncedItems(current_buffer_id_idx,
        \   capacity, a:buffer_padding, 'right')

    return [left_idx, right_idx]
endfunction
" ===
" GetTruncedItems: Calculate trunced items from the capacity.
" GetTruncedIndex XXX
" @bufid_idx (Number):
" current_buffer_id_idx
" "left"
" capacity after remove current_buffer
" padding
" => (List):
"   $1|{idx} (Number): the number of trunced items
"   $2|{capacity} (Number): the capacity left after calculated
"
" Description: Trunced buffers below and above of current buffer; Left is
" looped down and vice versa;
"           _
" | 0 | 1 | 2 | 3 |
" ===
function! s:GetTruncedItems(bufid_idx, capacity, padding, side)
    let start = (a:side=='left' ? a:bufid_idx-1 : a:bufid_idx+1 )
    let end   = (a:side=='left' ? 0             : len(s:buffers)-1 )
    let step  = (a:side=='left' ? -1            : 1 )

    let cap   = a:capacity
    let idx   = v:null

    for idx in range(start, end, step)
        let buffer = s:buffers[s:buffer_ids[idx]]

        if (buffer.length + a:padding) <= cap
            let cap = cap - buffer.length - a:padding
        else
            let idx = (a:side=='left' ? idx+1 : idx-1 )
            break           " If I don't set this there will be an error with the buffer at last
        endif
    endfor

    return [idx, cap]
endfunction
















function! s:IsBufferElement(element)
    if index(g:buffet_buffer_types, a:element.type) >= 0
        return 1
    endif
    return 0
endfunction


function! s:Len(string)
    let visible_singles = substitute(a:string, '[^\d0-\d127]', "-", "g")

    return len(visible_singles)
endfunction

function! s:GetTypeHighlight(type)
    return "%#" . g:buffet_prefix . a:type . "#"
endfunction



function! s:GetBuffer(buffer)
    if empty(a:buffer) && s:last_current_buffer_id >= 0
        let btarget = s:last_current_buffer_id
    elseif a:buffer =~ '^\d\+$'
        let btarget = bufnr(str2nr(a:buffer))
    else
        let btarget = bufnr(a:buffer)
    endif

    return btarget
endfunction

function! buffet#bswitch(index)
    let i = str2nr(a:index) - 1
    if i < 0 || i > len(s:buffer_ids) - 1
        echohl ErrorMsg
        echom "Invalid buffer index"
        echohl None
        return
    endif
    let buffer_id = s:buffer_ids[i]
    execute 'silent buffer ' . buffer_id
endfunction

" inspired and based on https://vim.fandom.com/wiki/Deleting_a_buffer_without_closing_the_window
function! buffet#bwipe(bang, buffer)
    let btarget = s:GetBuffer(a:buffer)

    let filters = get(g:, "buffet_bwipe_filters", [])
    if type(filters) == type([])
        for f in filters
            if function(f)(a:bang, btarget) > 0
                return
            endif
        endfor
    endif

    if btarget < 0
        echohl ErrorMsg
        call 'No matching buffer for ' . a:buffer
        echohl None

        return
    endif

    if empty(a:bang) && getbufvar(btarget, '&modified')
        echohl ErrorMsg
        echom 'No write since last change for buffer ' . btarget . " (add ! to override)"
        echohl None
        return
    endif

    " IDs of windows that view target buffer which we will delete.
    let wnums = filter(range(1, winnr('$')), 'winbufnr(v:val) == btarget')

    let wcurrent = winnr()
    for w in wnums
        " switch to window with ID 'w'
        execute 'silent ' . w . 'wincmd w'

        let prevbuf = bufnr('#')
        " if the previous buffer is another listed buffer, switch to it...
        if prevbuf > 0 && buflisted(prevbuf) && prevbuf != btarget
            buffer #
        " ...otherwise just go to the previous buffer in the list.
        else
            bprevious
        endif

        " if the 'bprevious' did not work, then just open a new buffer
        if btarget == bufnr("%")
            execute 'silent enew' . a:bang
        endif
    endfor

    " finally wipe the tarbet buffer
    execute 'silent bwipe' . a:bang . " " . btarget
    " switch back to original window
    execute 'silent ' . wcurrent . 'wincmd w'
endfunction

function! buffet#bonly(bang, buffer)
    let btarget = s:GetBuffer(a:buffer)

    for b in s:buffer_ids
        if b == btarget
            continue
        endif

        call buffet#bwipe(a:bang, b)
    endfor
endfunction

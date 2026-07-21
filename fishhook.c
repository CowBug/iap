#include "fishhook.h"
#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>

#ifdef __LP64__
typedef struct mach_header_64     mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64         section_t;
typedef struct nlist_64           nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header        mach_header_t;
typedef struct segment_command    segment_command_t;
typedef struct section            section_t;
typedef struct nlist              nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

struct rebindings_entry {
    struct rebinding      *rebindings;
    size_t                 rebindings_nel;
    struct rebindings_entry *next;
};

static struct rebindings_entry *_rebindings_head;

static int prepend_rebindings(struct rebindings_entry **head,
                              struct rebinding rebindings[],
                              size_t nel) {
    struct rebindings_entry *entry = malloc(sizeof(*entry));
    if (!entry) return -1;
    entry->rebindings     = malloc(nel * sizeof(struct rebinding));
    if (!entry->rebindings) { free(entry); return -1; }
    memcpy(entry->rebindings, rebindings, nel * sizeof(struct rebinding));
    entry->rebindings_nel = nel;
    entry->next = *head;
    *head = entry;
    return 0;
}

static void perform_rebinding_with_section(struct rebindings_entry *entry,
                                           section_t *section,
                                           intptr_t slide,
                                           nlist_t *symtab,
                                           char *strtab,
                                           uint32_t *indirect_symtab) {
    uint32_t *indices = indirect_symtab + section->reserved1;
    void **syms = (void**)((uintptr_t)slide + section->addr);

    for (uint32_t i = 0; i < section->size / sizeof(void*); i++) {
        uint32_t symIdx = indices[i];
        if (symIdx == INDIRECT_SYMBOL_LOCAL || symIdx == INDIRECT_SYMBOL_ABS)
            continue;

        uint32_t strtab_off = symtab[symIdx].n_un.n_strx;
        char *symname = strtab + strtab_off;
        bool found = false;

        struct rebindings_entry *cur = entry;
        while (cur) {
            for (size_t j = 0; j < cur->rebindings_nel; j++) {
                if (strcmp(symname, cur->rebindings[j].name) == 0) {
                    if (cur->rebindings[j].replaced)
                        *cur->rebindings[j].replaced = syms[i];
                    syms[i] = cur->rebindings[j].replacement;
                    found = true;
                    break;
                }
            }
            if (found) break;
            cur = cur->next;
        }
    }
}

int rebind_symbols_image(void *header, intptr_t slide,
                         struct rebinding rebindings[], size_t rebindings_nel) {
    struct rebindings_entry *entry = NULL;
    int ret = prepend_rebindings(&entry, rebindings, rebindings_nel);
    if (ret < 0) return ret;

    if (entry != NULL) {
        entry->next = _rebindings_head;
        _rebindings_head = entry;
    }

    mach_header_t *hdr = (mach_header_t*)header;
    segment_command_t *curSeg = (segment_command_t*)((uintptr_t)hdr + sizeof(mach_header_t));
    segment_command_t *linkedit = NULL;
    struct symtab_command *symtab_cmd = NULL;
    struct dysymtab_command *dysymtab_cmd = NULL;

    uintptr_t cur = (uintptr_t)curSeg;
    for (uint32_t i = 0; i < hdr->ncmds; i++, cur += curSeg->cmdsize) {
        curSeg = (segment_command_t*)cur;
        if (curSeg->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(curSeg->segname, SEG_LINKEDIT) == 0) {
                linkedit = curSeg;
            }
        } else if (curSeg->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command*)curSeg;
        } else if (curSeg->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (struct dysymtab_command*)curSeg;
        }
    }

    if (!linkedit || !symtab_cmd || !dysymtab_cmd) return -1;

    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    nlist_t *symtab_ptr = (nlist_t*)(base + symtab_cmd->symoff);
    char *strtab_ptr = (char*)(base + symtab_cmd->stroff);
    uint32_t *indirect = (uint32_t*)(base + dysymtab_cmd->indirectsymoff);

    cur = (uintptr_t)hdr + sizeof(mach_header_t);
    for (uint32_t i = 0; i < hdr->ncmds; i++, cur += curSeg->cmdsize) {
        curSeg = (segment_command_t*)cur;
        if (curSeg->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(curSeg->segname, SEG_DATA) != 0 &&
                strcmp(curSeg->segname, SEG_DATA_CONST) != 0) {
                continue;
            }
            for (uint32_t j = 0; j < curSeg->nsects; j++) {
                section_t *sect = (section_t*)((uintptr_t)curSeg + sizeof(segment_command_t) + j * sizeof(section_t));
                if ((sect->flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS ||
                    (sect->flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS) {
                    perform_rebinding_with_section(entry, sect, slide, symtab_ptr, strtab_ptr, indirect);
                }
            }
        }
    }

    return 0;
}

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
    int retval = prepend_rebindings(&_rebindings_head, rebindings, rebindings_nel);
    if (retval < 0) return retval;

    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
        retval = rebind_symbols_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i),
                                      rebindings, rebindings_nel);
    }
    return retval;
}

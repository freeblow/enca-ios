//
//  ViewController.m
//  TestEnca
//
//  Created by freeblow on 2019/3/20.
//  Copyright © 2019 freeblow. All rights reserved.
//

#import "ViewController.h"

#import <libenca-ios/enca.h>
#import <libenca-ios/common.h>


/**
 * Checks for doubly-encoded UTF-8 and prints a line when it looks so.
 **/
static void double_utf8_chk(EncaAnalyser an,
                const unsigned char *sample,
                size_t size)
{
    size_t dbl, i;
    int *candidates;
    
    if (options.output_type != OTYPE_DETAILS
        && options.output_type != OTYPE_HUMAN)
        return;
    
    dbl = enca_double_utf8_check(an, sample, size);
    if (!dbl)
        return;
    
    candidates = enca_double_utf8_get_candidates(an);
    if (candidates == NULL)
        return;
    if (dbl == 1)
        printf("  Doubly-encoded to UTF-8 from");
    else
        printf("  Doubly-encoded to UTF-8 from one of:");
    
    for (i = 0; i < dbl; i++)
        printf(" %s", enca_charset_name(candidates[i], ENCA_NAME_STYLE_ENCA));
    
    putchar('\n');
    enca_free(candidates);
}


/**
 * Reformats surface names as returned from enca_get_surface_name() one
 * per line to be indented and prints them.
 **/
static void
indent_surface(const char *s)
{
    const char *p;
    
    while ((p = strchr(s, '\n')) != NULL) {
        p++;
        printf("  %.*s", (int)(p-s), s);
        s = p;
    }
}

/**
 * Prints results.
 **/
static void
print_results(const char *fname,
              EncaAnalyser an,
              EncaEncoding result,
              int gerrno)
{
    char *s;
    EncaSurface surf = result.surface
    & ~enca_charset_natural_surface(result.charset);
    
    options.output_type = OTYPE_HUMAN;
    
    if (options.prefix_filename)
        printf("%s: ", ffname_r(fname));
    
    switch (options.output_type) {
        case OTYPE_ALIASES:
            print_aliases(result.charset);
            break;
            
        case OTYPE_CANON:
            if (surf) {
                s = enca_get_surface_name(surf, ENCA_NAME_STYLE_ENCA);
                fputs(enca_charset_name(result.charset, ENCA_NAME_STYLE_ENCA), stdout);
                puts(s);
                enca_free(s);
            }
            else
                puts(enca_charset_name(result.charset, ENCA_NAME_STYLE_ENCA));
            break;
            
        case OTYPE_HUMAN:
        case OTYPE_DETAILS:
            if (surf) {
                s = enca_get_surface_name(surf, ENCA_NAME_STYLE_HUMAN);
                puts(enca_charset_name(result.charset, ENCA_NAME_STYLE_HUMAN));
                indent_surface(s);
                enca_free(s);
            }
            else
                puts(enca_charset_name(result.charset, ENCA_NAME_STYLE_HUMAN));
            break;
            
        case OTYPE_RFC1345:
            puts(enca_charset_name(result.charset, ENCA_NAME_STYLE_RFC1345));
            break;
            
        case OTYPE_CS2CS:
            if (enca_charset_name(result.charset, ENCA_NAME_STYLE_CSTOCS) != NULL)
                puts(enca_charset_name(result.charset, ENCA_NAME_STYLE_CSTOCS));
            else
                puts(enca_charset_name(ENCA_CS_UNKNOWN, ENCA_NAME_STYLE_CSTOCS));
            break;
            
        case OTYPE_ICONV:
            if (enca_charset_name(result.charset, ENCA_NAME_STYLE_ICONV) != NULL)
                puts(enca_charset_name(result.charset, ENCA_NAME_STYLE_ICONV));
            else
                puts(enca_charset_name(ENCA_CS_UNKNOWN, ENCA_NAME_STYLE_ICONV));
            break;
            
        case OTYPE_MIME:
            if (enca_charset_name(result.charset, ENCA_NAME_STYLE_MIME) != NULL)
                puts(enca_charset_name(result.charset, ENCA_NAME_STYLE_MIME));
            else
                puts(enca_charset_name(ENCA_CS_UNKNOWN, ENCA_NAME_STYLE_MIME));
            break;
            
        default:
            abort();
            break;
    }
    
    if (gerrno && options.output_type == OTYPE_DETAILS) {
        printf("  Failure reason: %s.\n", enca_strerror(an, gerrno));
    }
}

/*
* DWIM
*
* Choose some suitable values of all the libenca tuning parameters.
*/
static void
dwim_libenca_options(EncaAnalyser an, const File *file)
{
    const double mu = 0.005;  /* derivation in 0 */
    const double m = 15.0;  /* value in infinity */
    ssize_t size = file->buffer->pos;
    size_t sgnf;
    
    /* The number of significant characters */
    if (!size)
        sgnf = 1;
    else
        sgnf = ceil((double)size/(size/m + 1.0/mu));
    enca_set_significant(an, sgnf);
    
    /* When buffer contains whole file, require correct termination. */
    if (file->size == size)
        enca_set_termination_strictness(an, 1);
    else
        enca_set_termination_strictness(an, 0);
    
    enca_set_filtering(an, sgnf > 2);
}

/* process file named fname
 this is the `boss' function
 returns 0 on succes, 1 on failure, 2 on troubles */
static int
process_file(EncaAnalyser an,
             const char *fname)
{
    static int utf8 = ENCA_CS_UNKNOWN;
    static Buffer *buffer = NULL; /* persistent i/o buffer */
    int ot_is_convert = (options.output_type == OTYPE_CONVERT);
    
    EncaEncoding result; /* the guessed encoding */
    File *file; /* the processed file */
    
    if (!an) {
        buffer_free(buffer);
        return 0;
    }
    
    /* Initialize when we are called the first time. */
    if (buffer == NULL)
        buffer = buffer_new(buffer_size);
    
    if (!enca_charset_is_known(utf8)) {
        utf8 = enca_name_to_charset("utf8");
        assert(enca_charset_is_known(utf8));
    }
    
    /* Read sample. */
    file = file_new(fname, buffer);
    if (file_open(file, ot_is_convert ? "r+b" : "r+b") != 0) {
        file_free(file);
        return EXIT_TROUBLE;
    }
    if (file_read(file) == -1) {
        file_free(file);
        return EXIT_TROUBLE;
    }
    if (!ot_is_convert)
        file_close(file);
    
    /* Guess encoding. */
    dwim_libenca_options(an, file);
    if (ot_is_convert)
        result = enca_analyse_const(an, buffer->data, buffer->pos);
    else
        result = enca_analyse(an, buffer->data, buffer->pos);
    
    /* Is conversion required? */
    if (ot_is_convert) {
        int err = 0;
        
        if (enca_charset_is_known(result.charset))
            err = convert(file, result);
        else {
            if (enca_errno(an) != ENCA_EEMPTY) {
                fprintf(stderr, "%s: Cannot convert `%s' from unknown encoding\n",
                        program_name,
                        ffname_r(file->name));
            }
            /* Copy stdin to stdout unchanged. */
            if (file->name == NULL)
                err = copy_and_convert(file, file, NULL);
        }
        
        file_free(file);
        if ((err == ERR_OK && !enca_charset_is_known(result.charset)
             && enca_errno(an) != ENCA_EEMPTY)
            || err == ERR_CANNOT)
            return EXIT_FAILURE;
        
        return (err == ERR_OK) ? EXIT_SUCCESS : EXIT_TROUBLE;
    }
    
    /* Print results. */
    print_results(file->name, an, result, enca_errno(an));
    if (result.charset == utf8)
        double_utf8_chk(an, buffer->data, buffer->pos);
    
    file_free(file);
    
    return enca_charset_is_known(result.charset) ? EXIT_SUCCESS : EXIT_FAILURE;
}

@interface ViewController ()

@end

@implementation ViewController

- (NSString *)applicationDocumentsDirectory
{
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
    EncaAnalyser an;
//    NSString *plistPath = [[NSBundle mainBundle] pathForResource:@"Info" ofType:@"plist"];
    
    NSString *plistPath = [[NSBundle mainBundle] pathForResource:@"readme.md" ofType:nil];
    
    NSString *newFilePath = [[self applicationDocumentsDirectory] stringByAppendingPathComponent:@"readme.md"];
    
    NSString *testFilePath = [[self applicationDocumentsDirectory] stringByAppendingPathComponent:@"test.txt"];
    NSError *error = nil;
    [@"test" writeToFile:testFilePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        NSLog(@"writeToFile error = %@",error);
    }
    
    NSLog(@"plistPath = %@",testFilePath);
    options.language = "zh";
    an = enca_analyser_alloc("zh");
    
//    [[NSFileManager defaultManager] moveItemAtURL:[NSURL URLWithString:plistPath] toURL:[NSURL URLWithString:newFilePath] error:&error];
//    if (error) {
//        NSLog(@"moveItemAtURL error = %@",error);
//    }
    
    process_file(an, [testFilePath UTF8String]);
}


@end

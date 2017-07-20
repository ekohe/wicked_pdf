# Wicked PDF [![Build Status](https://secure.travis-ci.org/mileszs/wicked_pdf.svg)](http://travis-ci.org/mileszs/wicked_pdf) [![Gem Version](https://badge.fury.io/rb/wicked_pdf.svg)](http://badge.fury.io/rb/wicked_pdf) [![Code Climate](https://codeclimate.com/github/mileszs/wicked_pdf/badges/gpa.svg)](https://codeclimate.com/github/mileszs/wicked_pdf)

## A PDF generation plugin for Ruby on Rails

This version of Wicked PDF uses Chrome Headless (available from version 59) to serve a PDF file to a user from HTML.  In other words, rather than dealing with a PDF generation DSL of some sort, you simply write an HTML view as you would normally, then let Wicked PDF take care of the hard stuff.

_Wicked PDF has been verified to work on Ruby versions 1.8.7 through 2.3; Rails 2 through 5.0_

### Installation

Add this to your Gemfile and run `bundle install`:

```ruby
gem 'wicked_pdf'
```

Then create the initializer with

    rails generate wicked_pdf

You may also need to add
```ruby
Mime::Type.register "application/pdf", :pdf
```
to `config/initializers/mime_types.rb` in older versions of Rails.

Because `wicked_pdf` is a wrapper for Chrome Headless, you'll need to install Chrome, too.

`wicked_pdf` tries to guess the location of Chrome, but if it can't find it, you can configure its location in an initializer:

```ruby
WickedPdf.config = {
  exe_path: '/usr/local/bin/Chrome'
}
```

As of June 2017, we recommend using Chrome Canary which has a better support for printToPDF.

Install Chrome Beta on Ubuntu:

Download the .deb file from here: https://www.google.com/chrome/browser/beta.html?platform=linux

Install using `sudo dpkg -i google-chrome-beta_current_amd64.deb`

Install missing dependencies with `sudo apt-get -f install`

Test if it's correctly installed with `/usr/bin/google-chrome --version`

### Basic Usage
```ruby
class ThingsController < ApplicationController
  def show
    respond_to do |format|
      format.html
      format.pdf do
        render pdf: "file_name"   # Excluding ".pdf" extension.
      end
    end
  end
end
```
### Usage Conditions - Important!

Chrome is run outside of your Rails application; therefore, your normal layouts will not work. If you plan to use any CSS, JavaScript, or image files, you must modify your layout so that you provide an absolute reference to these files. The best option for Rails without the asset pipeline is to use the `wicked_pdf_stylesheet_link_tag`, `wicked_pdf_image_tag`, and `wicked_pdf_javascript_include_tag` helpers or to go straight to a CDN (Content Delivery Network) for popular libraries such as jQuery.

#### wicked_pdf helpers
```html
<!doctype html>
<html>
  <head>
    <meta charset='utf-8' />
    <%= wicked_pdf_stylesheet_link_tag "pdf" -%>
    <%= wicked_pdf_javascript_include_tag "number_pages" %>
  </head>
  <body onload='number_pages'>
    <div id="header">
      <%= wicked_pdf_image_tag 'mysite.jpg' %>
    </div>
    <div id="content">
      <%= yield %>
    </div>
  </body>
</html>
```

Using wicked_pdf_helpers with asset pipeline raises `Asset names passed to helpers should not include the "/assets/" prefix.` error. To work around this, you can use `wicked_pdf_asset_base64` with the normal Rails helpers, but be aware that this will base64 encode your content and inline it in the page. This is very quick for small assets, but large ones can take a long time.

```html
<!doctype html>
<html>
  <head>
    <meta charset='utf-8' />
    <%= stylesheet_link_tag wicked_pdf_asset_base64("pdf") %>
    <%= javascript_include_tag wicked_pdf_asset_base64("number_pages") %>

  </head>
  <body onload='number_pages'>
    <div id="header">
      <%= image_tag wicked_pdf_asset_base64('mysite.jpg') %>
    </div>
    <div id="content">
      <%= yield %>
    </div>
  </body>
</html>
```

#### Asset pipeline usage

It is best to precompile assets used in PDF views. This will help avoid issues when it comes to deploying, as Rails serves asset files differently between development and production (`config.assets.comple = false`), which can make it look like your PDFs work in development, but fail to load assets in production.

    config.assets.precompile += ['blueprint/screen.css', 'pdf.css', 'jquery.ui.datepicker.js', 'pdf.js', ...etc...]

#### CDN reference

In this case, you can use that standard Rails helpers and point to the current CDN for whichever framework you are using. For jQuery, it would look somethng like this, given the current versions at the time of this writing.
```html
    <!doctype html>
    <html>
      <head>
        <%= javascript_include_tag "http://code.jquery.com/jquery-1.10.0.min.js" %>
        <%= javascript_include_tag "http://code.jquery.com/ui/1.10.3/jquery-ui.min.js" %>
```

### Advanced Usage with all available options
```ruby
class ThingsController < ApplicationController
  def show
    respond_to do |format|
      format.html
      format.pdf do
        render pdf:                            'file_name',
               disposition:                    'attachment',                 # default 'inline'
               template:                       'things/show',
               file:                           "#{Rails.root}/files/foo.erb"
               layout:                         'pdf',                        # for a pdf.pdf.erb file
               printBackground: true, # Print background graphics. Defaults to false.
               landscape: false, # Paper orientation. Defaults to false.
               paperHeight: 11.69, # Paper height in inches. Defaults to 11 inches.
               paperWidth: 8.27, # Paper width in inches. Defaults to 8.5 inches.
               marginTop: 0.2,
               marginBottom: 0.2,
               marginLeft: 0.2,
               marginRight: 0.2,
               scale: 1, # Scale of the webpage rendering. Defaults to 1.
               displayHeaderFooter: false, # Display header and footer. Defaults to false.
               pageRanges: '', # Paper ranges to print, e.g., '1-5, 8, 11-13'.
               pageCounterFunction: 'addPageNumbers'
      end
    end
  end
end
```
By default, it will render without a layout (layout: false) and the template for the current controller and action.

### Super Advanced Usage ###

If you need to just create a pdf and not display it:
```ruby
# create a pdf from a string
pdf = WickedPdf.new.pdf_from_string('<h1>Hello There!</h1>')

# create a pdf file from a html file without converting it to string
# Path must be absolute path
pdf = WickedPdf.new.pdf_from_html_file('/your/absolute/path/here')

# create a pdf from a URL
pdf = WickedPdf.new.pdf_from_url('https://github.com/mileszs/wicked_pdf')

# create a pdf from string using templates, layouts and content option for header or footer
pdf = WickedPdf.new.pdf_from_string(
  render_to_string('templates/pdf', layout: 'pdfs/layout_pdf.html'),
  footer: {
    content: render_to_string(
  		'templates/footer',
  		layout: 'pdfs/layout_pdf.html'
  	)
  }
)

# It is possible to use footer/header templates without a layout, in that case you need to provide a valid HTML document
pdf = WickedPdf.new.pdf_from_string(
  render_to_string('templates/full_pdf_template'),
  header: {
    content: render_to_string('templates/full_header_template')
  }
)

# or from your controller, using views & templates and all wicked_pdf options as normal
pdf = render_to_string pdf: "some_file_name", template: "templates/pdf", encoding: "UTF-8"

# then save to a file
save_path = Rails.root.join('pdfs','filename.pdf')
File.open(save_path, 'wb') do |file|
  file << pdf
end
```
If you need to display utf encoded characters, add this to your pdf views or layouts:
```html
<meta charset="utf-8" />
```

### Page Breaks

You can control page breaks with CSS.

Add a few styles like this to your stylesheet or page:
```css
div.alwaysbreak { page-break-before: always; }
div.nobreak:before { clear:both; }
div.nobreak { page-break-inside: avoid; }
```

### Page Numbering

A bit of javascript can help you number your pages.
Use the option `pageCounterFunction` to define a function to draw page numbers.

For example:
```js
window.addPageNumbers = function(count,
                                 pageWidth,
                                 pageHeight,
                                 marginTop,
                                 marginRight,
                                 marginBottom,
                                 marginLeft) {
  // All units are in inches
  var bottomPosition = 0.2;
  var rightPosition = 0.9;
  var pageHeightError = 0.0017; // empirical..

  var $body = $('body#body_pdf');
  $body.css('width', (pageWidth - marginLeft - marginRight) + 'in !important');
  $body.css('margin', '0px !important');
  $body.css('padding', '0px !important');

  var i = 0;

  var pageHeight = (pageHeight - marginTop - marginBottom + pageHeightError);
  var firstPageNumberAt = pageHeight - bottomPosition;
  var left = pageWidth - marginRight - marginLeft - rightPosition;

  while (i < count) {
    var top = firstPageNumberAt + (i*pageHeight);
    var number = $("<div class='footer_page_number' style='position: absolute; left: "+left+"in; top: "+top+"in;'>Page "+(i+1)+" of "+count+"</div>");
    number.appendTo('body');
    i = i + 1;
  }

  return "Added "+count+" page numbers!";
};
```

### Configuration

You can put your default configuration, applied to all pdf's at "wicked_pdf.rb" initializer.

### Rack Middleware

If you would like to have WickedPdf automatically generate PDF views for all (or nearly all) pages by appending .pdf to the URL, add the following to your Rails app:
```ruby
# in application.rb (Rails3) or environment.rb (Rails2)
require 'wicked_pdf'
config.middleware.use WickedPdf::Middleware
```
If you want to turn on or off the middleware for certain urls, use the `:only` or `:except` conditions like so:
```ruby
# conditions can be plain strings or regular expressions, and you can supply only one or an array
config.middleware.use WickedPdf::Middleware, {}, only: '/invoice'
config.middleware.use WickedPdf::Middleware, {}, except: [ %r[^/admin], '/secret', %r[^/people/\d] ]
```
If you use the standard `render pdf: 'some_pdf'` in your app, you will want to exclude those actions from the middleware.

### Further Reading

https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-printToPDF

### Debugging

Now you can use a debug param on the URL that shows you the content of the pdf in plain html to design it faster.

First of all you must configure the render parameter `show_as_html: params.key?('debug')` and then just use it like you normally would but add "debug" as a GET param in the URL:

http://localhost:3001/CONTROLLER/X.pdf?debug

However, the wicked_pdf_* helpers will use file:/// paths for assets when using :show_as_html, and your browser's cross-domain safety feature will kick in, and not render them. To get around this, you can load your assets like so in your templates:
```html
    <%= params.key?('debug') ? image_tag('foo') : wicked_pdf_image_tag('foo') %>
```

#### Gotchas

If one image from your HTML cannot be found (relative or wrong path for ie), others images with right paths **may not** be displayed in the output PDF as well (it seems to be an issue with wkhtmltopdf).

### Inspiration

You may have noticed: this plugin is heavily inspired by the PrinceXML plugin [princely](http://github.com/mbleigh/princely/tree/master).  PrinceXML's cost was prohibitive for me. So, with a little help from some friends (thanks [jqr](http://github.com/jqr)), I tracked down wkhtmltopdf, and here we are.

### Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Run the test suite and check the output (`rake`)
4. Add tests for your feature or fix (please)
5. Commit your changes (`git commit -am 'Add some feature'`)
6. Push to the branch (`git push origin my-new-feature`)
7. Create new Pull Request

### Awesome People

Also, thanks to [unixmonkey](https://github.com/Unixmonkey), [galdomedia](http://github.com/galdomedia), [jcrisp](http://github.com/jcrisp), [lleirborras](http://github.com/lleirborras), [tiennou](http://github.com/tiennou), and everyone else for all their hard work and patience with my delays in merging in their enhancements.

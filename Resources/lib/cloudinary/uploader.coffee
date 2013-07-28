_ = require("../underscore")
utils = require("./utils")
config = require("./config")

build_eager = (transformations) ->
  (for transformation in utils.build_array(transformations)
    transformation = _.clone(transformation)
    _.filter([utils.generate_transformation_string(transformation), transformation.format], utils.present).join("/")
  ).join("|")

build_custom_headers = (headers) ->
  if !headers?
    return undefined
  else if _.isArray(headers)
  else if _.isObject(headers)
    headers = [k + ": " + v for k, v of headers]
  else
    return headers
  return headers.join("\n")

build_upload_params = (options) ->
  params =
    timestamp: utils.timestamp(),
    transformation: utils.generate_transformation_string(options),
    public_id: options.public_id,
    callback: options.callback,
    format: options.format,
    backup: options.backup,
    faces: options.faces,
    exif: options.exif,
    image_metadata: options.image_metadata,
    colors: options.colors,
    type: options.type,
    eager: build_eager(options.eager),
    headers: build_custom_headers(options.headers),
    use_filename: options.use_filename,
    notification_url: options.notification_url,
    eager_notification_url: options.eager_notification_url,
    eager_async: options.eager_async,
    invalidate: options.invalidate,
    tags: options.tags && utils.build_array(options.tags).join(",")
  params

exports.upload_stream = (callback, options={}) ->
  fs = require('fs')
  path = require('path')
  temp = require('temp')

  temp_filename = temp.path()
  temp_file = fs.createWriteStream temp_filename,
    flags: 'w',
    encoding: 'binary',
    mode: 0o600

  stream =
    write: (data) ->
      temp_file.write(new Buffer(data, 'binary'))
    end: ->
      temp_file.on "close", ->
        try
          exports.upload temp_filename, finish, options
        catch e
          finish(error: {message: e})
      temp_file.end()

      finish = (result) ->
        fs.unlink(temp_filename)
        callback.call(null, result)
  stream

exports.upload = (file, callback, options={}) ->
  call_api "upload", callback, options, ->
    params = build_upload_params(options)
    if typeof(file) == 'string'
      if (file.match(/^https?:/) || file.match(/^data:image\/\w*;base64,([a-zA-Z0-9\/+\n=]+)$/))
        return [params, file: file]
      else
        file = '../../' + file if file[0] != '/'
        return [params, {}, Ti.Filesystem.getFile file]
    else
      return [params, {}, file]

exports.explicit = (public_id, callback, options={}) ->
  call_api "explicit", callback, options, ->
    return [
      timestamp: utils.timestamp()
      type: options.type
      public_id: public_id
      callback: options.callback
      eager: build_eager(options.eager)
      headers: build_custom_headers(options.headers)
      tags: options.tags ? utils.build_array(options.tags).join(",")
    ]

exports.destroy = (public_id, callback, options={}) ->
  call_api "destroy", callback, options, ->
    return [timestamp: utils.timestamp(), type: options.type, invalidate: options.invalidate,public_id:  public_id]

exports.rename = (from_public_id, to_public_id, callback, options={}) ->
  call_api "rename", callback, options, ->
    return [timestamp: utils.timestamp(), type: options.type, from_public_id: from_public_id, to_public_id: to_public_id, overwrite: options.overwrite]

TEXT_PARAMS = ["public_id", "font_family", "font_size", "font_color", "text_align", "font_weight", "font_style", "background", "opacity", "text_decoration"]
exports.text = (text, callback, options={}) ->
  call_api "text", callback, options, ->
    params = {timestamp: utils.timestamp(), text: text}
    for k in TEXT_PARAMS when options[k]?
      params[k] = options[k]
    [params]

exports.generate_sprite = (tag, callback, options={}) ->
  call_api "sprite", callback, options, ->
    transformation = utils.generate_transformation_string(_.extend(options, fetch_format: options.format))
    return [{timestamp: utils.timestamp(), tag: tag, transformation: transformation, async: options.async, notification_url: options.notification_url}]

exports.multi = (tag, callback, options={}) ->
  call_api "multi", callback, options, ->
    transformation = utils.generate_transformation_string(_.extend(options))
    return [{timestamp: utils.timestamp(), tag: tag, transformation: transformation, format: options.format, async: options.async, notification_url: options.notification_url}]

exports.explode = (public_id, callback, options={}) ->
  call_api "explode", callback, options, ->
    transformation = utils.generate_transformation_string(_.extend(options))
    return [{timestamp: utils.timestamp(), public_id: public_id, transformation: transformation, format: options.format, type: options.type, notification_url: options.notification_url}]

# options may include 'exclusive' (boolean) which causes clearing this tag from all other resources
exports.add_tag = (tag, public_ids = [], callback, options = {}) ->
  exclusive = utils.option_consume("exclusive", options)
  command = if exclusive then "set_exclusive" else "add"
  call_tags_api(tag, command, public_ids, callback, options)

exports.remove_tag = (tag, public_ids = [], callback, options = {}) ->
  call_tags_api(tag, "remove", public_ids, callback, options)

exports.replace_tag = (tag, public_ids = [], callback, options = {}) ->
  call_tags_api(tag, "replace", public_ids, callback, options)

call_tags_api = (tag, command, public_ids = [], callback, options = {}) ->
  call_api "tags", callback, options, ->
    return [{timestamp: utils.timestamp(), tag: tag, public_ids: utils.build_array(public_ids), command:  command, type: options.type}]

call_api = (action, callback, options, get_params) ->
  options = _.clone(options)
  api_key = options.api_key ? config().api_key ? throw("Must supply api_key")
  api_secret = options.api_secret ? config().api_secret ? throw("Must supply api_secret")

  [params, unsigned_params, file] = get_params.call()

  params.signature = utils.api_sign_request(params, api_secret)
  params.api_key = api_key
  params = _.extend(params, unsigned_params)
  params.file = file if file

  api_url = utils.api_url(action, options)

  xhr = Ti.Network.createHTTPClient
    onload: ->
      if _.include([200,400,401,500], @status)
        try
          result = JSON.parse(@responseText)
        catch e
          result = {error: {message: "Server return invalid JSON response. Status Code #{@status}"}}
        result["error"]["http_code"] = @status if result["error"]
        callback(result)
      else
        callback(error: {message: "Server returned unexpected status code - #{@status}"})
    onerror: (e) ->
      callback(error: e)
    timeout: options["timeout"] ? 60*1000

  xhr.open 'POST', api_url
  if file
    xhr.setRequestHeader "enctype", "multipart/form-data"
    Ti.API.log 'XHR' + JSON.stringify(xhr)
    Ti.API.log 'params' + JSON.stringify(params)
    xhr.send params
  else
    xhr.setRequestHeader("Content-Type", "application/json; charset=utf-8")
    Ti.API.log 'XHR' + JSON.stringify(xhr)
    Ti.API.log 'params' + JSON.stringify(params)
    xhr.send JSON.stringify(params)

exports.direct_upload = (callback_url, options) ->
  params = build_upload_params(_.extend({callback: callback_url}, options))
  params.signature = utils.api_sign_request(params, config().api_secret)
  params.api_key = config().api_key

  api_url = utils.api_url("upload", options)

  for k, v of params when not utils.present(v)
    delete params[k]

  return hidden_fields: params, form_attrs: {action: api_url, method: "POST", enctype: "multipart/form-data"}


exports.image_upload_tag = (field, options={}) ->
  html_options = options.html ? {}
  options.resource_type ?= "auto"
  cloudinary_upload_url = utils.api_url("upload", options)

  api_key = options.api_key ? config().api_key ? throw("Must supply api_key")
  api_secret = options.api_secret ? config().api_secret ? throw("Must supply api_secret")

  params = build_upload_params(options)
  params["signature"] = utils.api_sign_request(params, api_secret)
  params["api_key"] = api_key

  # Remove blank parameters
  for k, v of params when not utils.present(v)
    delete params[k]

  tag_options = _.extend(html_options, {
      type: "file",
      name: "file",
      "data-url": cloudinary_upload_url,
      "data-form-data": JSON.stringify(params),
      "data-cloudinary-field": field,
      "class": [html_options["class"], "cloudinary-fileupload"].join(" ")
  })
  return '<input ' + utils.html_attrs(tag_options) + '/>'


require 'rest-client'
require 'pathname'
require 'find'
require 'digest/md5'
require 'json'

module CloudDrive

  class Node

    def initialize(account)
      @account = account
    end

    def build_node_path(node)
      path = []
      loop do
        path.push node["name"]

        break if node.has_key?('isRoot') && node['isRoot'] == true

        results = find_by_id(node["parents"][0])
        if results[:success] == false
          raise "No parent node found with ID #{node["parents"][0]}"
        end

        node = results[:data]

        break if node.has_key?('isRoot') && node['isRoot'] === true
      end

      path = path.reverse
      path.join('/')
    end

    def create_new_folder(name, parent_id = nil)
      if parent_id == nil
        parent_id = get_root['id']
      end

      body = {
          :name => name,
          :parents => [
              parent_id
          ],
          :kind => "FOLDER"
      }

      retval = {
          :success => false,
          :data => []
      }

      RestClient.post(
          "#{@account.metadata_url}nodes",
          body.to_json,
          :Authorization => "Bearer #{@account.access_token}"
      ) do |response, request, result|
        data = JSON.parse(response.body)
        retval[:data] = data
        if response.code === 201
          retval[:success] = true
          @account.save_node(data)
        end
      end

      retval
    end

    def create_directory_path(path)
      retval = {
        :success => true,
        :data => {}
      }

      path = get_path_array(path)
      previous_node = get_root

      match = nil
      path.each_with_index do |folder, index|
        xary = path.slice(0, index + 1)
        if (match = find_by_path(xary.join('/'))) === nil
          result = create_new_folder(folder, previous_node["id"])
          if result[:success] === false
            return result
          end

          match = result[:data]
        end

        previous_node = match
      end

      if match == nil
        retval[:data] = previous_node
      else
        retval[:data] = match
      end

      retval
    end

    # If given a local file, the MD5 will be compared as well
    def exists?(remote_file, local_file = nil)
      if (file = find_by_path(remote_file)) == nil
        if local_file != nil
          if (file = find_by_md5(Digest::MD5.file(local_file).to_s)) != nil
            path = build_node_path(file)
            return {
                :success => true,
                :data => {
                    "message" => "File with same MD5 exists at #{path}: #{file.to_json}",
                    "path_match" => false,
                    "md5_match" => true
                }
            }
          end
        end
        return {
            :success => false,
            :data => {
                "message" => "File #{remote_file} does not exist"
            }
        }
      end

      retval = {
          :success => true,
          :data => {
              "message" => "File #{remote_file} exists",
              "path_match" => true,
              "md5_match" => false,
              "node" => file
          }
      }

      if local_file != nil
        if file["contentProperties"] != nil && file["contentProperties"]["md5"] != nil
          if Digest::MD5.file(local_file).to_s != file["contentProperties"]["md5"]
            retval[:data]["message"] = "File #{remote_file} exists but checksum doesn't match"
          else
            retval[:data]["message"] = "File #{remote_file} exists and is identical"
            retval[:data]["md5_match"] = true
          end
        else
          retval[:data]["message"] = "File #{remote_file} exists, but no checksum is available"
        end
      end

      retval
    end

    def find_by_id(id)
      retval = {
          :success => false,
          :data => {}
      }

      results = @account.db.execute("SELECT raw_data FROM nodes WHERE id = ?;", id)
      if results.empty?
        return retval
      end

      if results.count > 1
        raise "Multiple nodes with same ID found: #{results[:data].to_json}"
      end

      {
          :success => true,
          :data => JSON.parse(results[0][0])
      }
    end

    def find_by_md5(hash)
      results = @account.db.execute("SELECT raw_data FROM nodes WHERE md5 = ?;", hash)
      if results.empty?
        return nil
      end

      if results.count > 1
        raise "Multiple nodes with same MD5: #{results.to_json}"
      end

      JSON.parse(results[0][0])
    end

    def find_by_name(name)
      retval = []
      results = @account.db.execute("SELECT raw_data FROM nodes WHERE name = ?;", name)
      if results.empty?
        return retval
      end

      results.each do |result|
          retval.push(JSON.parse(result[0]))
      end

      retval
    end

    def find_by_path(path)
      path = path.gsub(/\A\//, '')
      path = path.gsub(/\/$/, '')

      if path == ''
        return get_root
      end

      path_info = Pathname.new(path)

      found_nodes = find_by_name(path_info.basename.to_s)
      if found_nodes.empty?
        return nil
      end

      match = nil
      found_nodes.each do |node|
        if build_node_path(node) == path
          match = node
        end
      end

      match
    end

    # @TODO: there's probably a better way to do this locally than check the last
    # `id` in the `parent` string is the parent...
    def get_children(id)
      retval = {
        :success => true,
        :data => []
      }

      nodes = @account.db.execute("SELECT raw_data FROM nodes WHERE parents LIKE '%#{id}';")
      if nodes.kind_of?(Array)
        nodes.each do |node|
          retval[:data].push(JSON.parse(node[0]))
        end
      else
        retval[:data] = JSON.parse(nodes)
      end

      retval
    end

    def get_path_array(path)
      return path if path.kind_of?(Array)

      path = path.split('/')
      path.reject! do |value|
        value.empty?
      end

      path
    end

    def get_path_string(path)
      path = path.join '/' if path.kind_of?(Array)

      path.chomp
    end

    def get_root
      results = find_by_name('root')
      if results.empty?
        raise "No node by the name of 'root' found in database"
      end

      results.each do |node|
        if node.has_key?('isRoot') && node['isRoot'] === true
          return node
        end
      end

      nil
    end

    def upload_dir(src_path, dest_root, overwrite = false, show_progress = false)
      src_path = File.expand_path(src_path)

      dest_root = get_path_array(dest_root)
      dest_root.push(get_path_array(src_path).last)
      dest_root = get_path_string(dest_root)

      retval = []
      Find.find(src_path) do |file|
        # Skip root directory, no need to make it
        next if file == src_path || File.directory?(file)

        path_info = Pathname.new(file)
        remote_dest = path_info.dirname.sub(src_path, dest_root).to_s

        result = upload_file(file, remote_dest, overwrite)
        if show_progress == true
          if result[:success] == true
            puts "Successfully uploaded file #{file}: #{result[:data].to_json}"
          else
            puts "Failed to uploaded file #{file}: #{result[:data].to_json}"
          end
        end

        retval.push(result)

        # Since uploading a directory can take a while (depending on number/size of files)
        # we will check if we need to renew our authorization after each file upload to
        # make sure our authentication doesn't expire.
        if (Time.new.to_i - @account.token_store["last_authorized"]) > 60
          result = @account.renew_authorization
          if result[:success] === false
            raise "Failed to renew authorization: #{result[:data].to_json}"
          end
        end
      end

      retval
    end

    def upload_file(src_path, dest_path, overwrite = false)
      retval = {
          :success => false,
          :data => {}
      }

      path_info = Pathname.new(src_path)
      dest_path = get_path_string(get_path_array(dest_path))

      result = create_directory_path(dest_path)
      return result if result[:success] == false

      dest_folder = result[:data]

      result = exists?("#{dest_path}/#{path_info.basename}", src_path)
      if result[:success] == true
        if overwrite == false
          retval[:data] = result[:data]

          return retval
        end

        if result[:data]["md5_match"]
          retval[:data]["message"] = "Identical file already exists at #{dest_path}."

          return retval
        end

        return overwrite_file(src_path, result[:data]["node"])
      end

      body = {
          :metadata => {
              :kind => 'FILE',
              :name => path_info.basename,
              :parents => [
                  dest_folder["id"]
              ]
          }.to_json,
          :content => File.new(File.expand_path(src_path), 'rb')
      }

      RestClient.post("#{@account.content_url}nodes", body, :Authorization => "Bearer #{@account.access_token}") do |response, request, result|
        retval[:data] = JSON.parse(response.body)
        if response.code === 201
          retval[:success] = true
          @account.save_node(retval[:data])
        end
      end

      retval
    end

    def overwrite_file(src_path, node)
      retval = {
        :success => false,
        :data => {}
      }

      body = {
          :content => File.new(File.expand_path(src_path), 'rb')
      }

      RestClient.put("#{@account.content_url}nodes/#{node["id"]}/content", body, :Authorization => "Bearer #{@account.access_token}") do |response, request, result|
        retval[:data] = JSON.parse(response.body)
        if response.code === 200
          retval[:success] = true
          @account.save_node(retval[:data])
        end
      end

      retval
    end

  end

end

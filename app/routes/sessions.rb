module ExercismWeb
  module Routes
    class Sessions < Core
      register ExercismWeb::Routes::GithubCallback

      get '/api_login/?*' do
        unless params[:code]
          halt 400, "Must provide parameter 'code'"
        end

        begin
          user = Authentication.perform(params[:code], github_client_id, github_client_secret, nil)
        rescue StandardError => e
          Bugsnag.notify(e, nil, request)
          json error: "We're having trouble with logins right now. Please come back later."
        end

        json user.to_json
      end
      
      get '/please-login' do
        erb :"auth/please_login", locals: {return_path: params[:return_path]}
      end

      get '/login' do
        q = {client_id: github_client_id}
        if params.has_key?("return_path")
          q[:redirect_uri] = [request.base_url, "github", "callback", params[:return_path]].join("/")
        end
        redirect Github.login_url(q)
      end

      get '/logout' do
        logout
        redirect root_path
      end
    end
  end
end
